#!/usr/bin/env bash
# =============================================================================
# NFTBan - commit-confirm / automatic rollback engine (v1.235, row 486 RP5 / D8)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="commit_confirm"
# meta:type="lib"
# meta:version="1.235.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="Repairs the JunOS-style commit-confirm mechanism (origin v0.10.0; orphaned since v1.0.0-beta). Contract: NFTBAN_ROADMAP/CLI_AUDIT_V1235/ROW486_BEHAVIOUR_CONTRACT_V1235.md §4. Last-known-good is the APPLIED BASELINE recorded at every successful rule load (never a snapshot taken when the risky command starts). The rollback is armed BEFORE the change, with the exact grace, under an apply ID; the candidate boot projection is published only at confirm (atomic rename = commit point); every outcome is durable (no in-progress limbo): a crash after the commit point is completed, before it is rolled back. Rollback restores only the change set and never overwrites a file edited again after the apply. A failed rollback KEEPS the current kernel state and alarms (owner D10); NFTBan never removes protection on its own."
# meta:inventory.files="/var/lib/nftban/state/applied/,/var/lib/nftban/state/commit-confirm/,/var/lib/nftban/state/commit-confirm.state,/var/lib/nftban/state/commit-confirm.rollback-failed"
# meta:inventory.binaries="nft,tar,sha256sum,flock,systemd-run,systemctl,find,sort"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_CONFIRM_GRACE_SECONDS,NFTBAN_REBOOT_GRACE_PERIOD"
# meta:inventory.privileges="root"
# =============================================================================

[[ -n "${_NFTBAN_COMMIT_CONFIRM_LOADED:-}" ]] && return 0 2>/dev/null || true
_NFTBAN_COMMIT_CONFIRM_LOADED=1

CC_STATE_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state"
CC_RECORD="${CC_STATE_DIR}/commit-confirm.state"
CC_FAILED_MARK="${CC_STATE_DIR}/commit-confirm.rollback-failed"
CC_LOCK="${CC_STATE_DIR}/commit-confirm.lock"
CC_BASE="${CC_STATE_DIR}/applied"
CC_WORK="${CC_STATE_DIR}/commit-confirm"
CC_CONFIG="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
CC_NFTBAN_BIN="${NFTBAN_BIN:-/usr/sbin/nftban}"

cc_now()   { date -u +%s; }
cc_utc()   { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?"; }
cc_sha()   { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Grace: NFTBAN_CONFIRM_GRACE_SECONDS; the misnamed legacy key is a deprecated alias.
cc_grace_default() {
    local g="${NFTBAN_CONFIRM_GRACE_SECONDS:-${NFTBAN_REBOOT_GRACE_PERIOD:-300}}"
    [[ "$g" =~ ^[0-9]+$ && "$g" -ge 30 && "$g" -le 86400 ]] || g=300
    printf '%s' "$g"
}

# key=value record I/O (atomic write)
cc_get() { [[ -r "$CC_RECORD" ]] || return 0; sed -n "s/^$1=//p" "$CC_RECORD"; return 0; }
cc_write_record() {  # key=value ...
    local tmp
    mkdir -p "$CC_STATE_DIR" || return 1
    tmp=$(mktemp "${CC_RECORD}.XXXXXX") || return 1
    printf '%s\n' "$@" > "$tmp" && chmod 640 "$tmp" && mv -f "$tmp" "$CC_RECORD"
}
cc_set() {  # key value: update one key, keep the others
    local k="$1" v="$2" tmp
    tmp=$(mktemp "${CC_RECORD}.XXXXXX") || return 1
    { [[ -r "$CC_RECORD" ]] && grep -v "^${k}=" "$CC_RECORD"; printf '%s=%s\n' "$k" "$v"; } > "$tmp" \
        && chmod 640 "$tmp" && mv -f "$tmp" "$CC_RECORD"
}

# Config manifest: "sha256  ./relative/path" for every file under the config dir
# except generated/ (generated state is not configuration).
cc_manifest() {  # dir
    ( cd "$1" 2>/dev/null || exit 1
      find . -path ./generated -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum )
}

# Copy the config inputs (excluding generated/) into a directory.
cc_copy_config() {  # src dst
    mkdir -p "$2" || return 1
    tar -C "$1" --exclude=./generated -cf - . 2>/dev/null | tar -C "$2" -xpf - 2>/dev/null
}

# -----------------------------------------------------------------------------
# Applied baseline: recorded after EVERY successful rule load that is not a pending
# candidate (plain rebuild, enable, installer rebuild) and at confirm.
# cc_record_applied_baseline <loaded_ruleset_file> [config_snapshot_dir]
# -----------------------------------------------------------------------------
cc_record_applied_baseline() {
    local loaded="$1" cfgsrc="${2:-$CC_CONFIG}" new proj
    mkdir -p "$CC_STATE_DIR" || return 1
    new=$(mktemp -d "${CC_BASE}.new.XXXXXX") || return 1
    cc_copy_config "$cfgsrc" "$new/config" || { rm -rf "$new"; return 1; }
    cc_manifest "$new/config" > "$new/manifest" || { rm -rf "$new"; return 1; }
    [[ -s "$loaded" ]] && cp -f "$loaded" "$new/ruleset.nft"
    proj="${CC_CONFIG}/generated/nftban-boot.nft"
    [[ -f "$proj" ]] && cp -f "$proj" "$new/projection.nft"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$new/meta"
    # No permission change here: mktemp -d creates "$new" 0700 (root-only), and the
    # stored files keep their ORIGINAL mode and owner (tar -p above, cp -p on restore),
    # so a rollback restores the metadata as well as the content.
    rm -rf "${CC_BASE}.old"
    [[ -d "$CC_BASE" ]] && mv -f "$CC_BASE" "${CC_BASE}.old"
    if mv -f "$new" "$CC_BASE"; then rm -rf "${CC_BASE}.old"; return 0; fi
    [[ -d "${CC_BASE}.old" ]] && mv -f "${CC_BASE}.old" "$CC_BASE"
    return 1
}

# The shared lock (fd 9). Every apply / confirm / rollback / boot decision holds it.
cc_lock()   { mkdir -p "$CC_STATE_DIR" && exec 9>"$CC_LOCK" && flock -w 60 9; }
# NB: no redirection on the exec: `exec 9>&- 2>/dev/null` would permanently send the
# whole shell's stderr to /dev/null and hide every later refusal or alarm.
cc_unlock() { flock -u 9 2>/dev/null || true; exec 9>&-; return 0; }

cc_status() { cc_get status; }

# Refusal used by every rule-loading path while a rollback has failed (owner D10:
# no silent change of the kernel state that recovery depends on).
cc_refuse_if_rollback_failed() {
    [[ -e "$CC_FAILED_MARK" ]] || return 0
    echo "REFUSED: $1: a commit-confirm ROLLBACK FAILED (apply $(cc_get apply_id)); the current kernel state is kept for recovery." >&2
    echo "  Reason: $(cc_get error)" >&2
    echo "  Recover: 'nftban firewall rollback $(cc_get apply_id)' (retry), or from the console" >&2
    echo "  'nftban disable all --flush-rules', or boot once with nftban=disabled." >&2
    return 1
}

# -----------------------------------------------------------------------------
# cc_apply_begin <grace>: called by `firewall rebuild --confirm` BEFORE it renders
# and loads. On success exports CC_APPLY_ID and returns 0; nothing has changed yet.
# -----------------------------------------------------------------------------
cc_apply_begin() {
    local grace="$1" id deadline now
    command -v flock >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1 \
        || { echo "REFUSED: rebuild --confirm needs flock and systemd-run" >&2; return 1; }
    cc_lock || { echo "REFUSED: commit-confirm lock busy" >&2; return 1; }
    if [[ -e "$CC_FAILED_MARK" ]]; then cc_unlock; cc_refuse_if_rollback_failed "rebuild --confirm"; return 1; fi
    if [[ "$(cc_status)" == "pending" ]]; then
        echo "REFUSED: apply $(cc_get apply_id) is still pending (deadline $(cc_utc "$(cc_get deadline_epoch)")). Confirm or roll it back first:" >&2
        echo "  nftban firewall confirm $(cc_get apply_id)    |    nftban firewall rollback $(cc_get apply_id)" >&2
        cc_unlock; return 1
    fi
    if [[ ! -f "$CC_BASE/manifest" || ! -d "$CC_BASE/config" ]]; then
        echo "REFUSED: no applied baseline (the configuration that produced the running rules is not recorded)." >&2
        echo "  It is recorded by every successful plain 'nftban firewall rebuild', 'nftban enable' and the installer." >&2
        cc_unlock; return 1
    fi
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    # Root-only like the baseline: the work dir holds a config copy and the kernel dump
    # (its parent state dir is 0750 nftban:nftban, created by cc_lock). Created fresh,
    # 0700, this one directory only.
    rm -rf "$CC_WORK"; mkdir -m 0700 "$CC_WORK" || { cc_unlock; return 1; }
    # Previous kernel rules: the exact NFTBan tables, dumped BEFORE the change.
    # Dump whichever NFTBan tables exist (ip6 may be absent on IPv4-only hosts).
    local _t _fam _ok=0
    if _t=$(nft list tables 2>"$CC_WORK/dump.err"); then
        : > "$CC_WORK/kernel-before.nft"
        for _fam in ip ip6; do
            grep -qx "table $_fam nftban" <<<"$_t" || continue
            nft list table "$_fam" nftban >> "$CC_WORK/kernel-before.nft" 2>>"$CC_WORK/dump.err" || { _ok=1; break; }
        done
        [[ -s "$CC_WORK/kernel-before.nft" ]] || _ok=1
    else
        _ok=1
    fi
    if [[ $_ok -ne 0 ]]; then
        echo "REFUSED: the current NFTBan tables could not be read; nothing to roll back to: $(head -c 300 "$CC_WORK/dump.err")" >&2
        rm -rf "$CC_WORK"; cc_unlock; return 1
    fi
    # The candidate configuration as it is NOW (what this apply is about to load).
    cc_copy_config "$CC_CONFIG" "$CC_WORK/candidate-config" && cc_manifest "$CC_WORK/candidate-config" > "$CC_WORK/candidate-manifest" \
        || { echo "REFUSED: candidate configuration could not be recorded" >&2; rm -rf "$CC_WORK"; cc_unlock; return 1; }
    # Change set: paths whose content differs between the applied baseline and the candidate.
    LC_ALL=C join -j2 -a1 -a2 -e MISSING -o 0,1.1,2.1 \
        <(awk '{print $1" "$2}' "$CC_BASE/manifest" | LC_ALL=C sort -k2) \
        <(awk '{print $1" "$2}' "$CC_WORK/candidate-manifest" | LC_ALL=C sort -k2) \
      | awk '$2!=$3 {print $1"\t"$2"\t"$3}' > "$CC_WORK/changeset"
    now=$(cc_now); deadline=$(( now + grace ))
    cc_write_record "apply_id=$id" "status=pending" "deadline_epoch=$deadline" "grace=$grace" \
        "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "candidate_projection_sha=" "confirm_requested=" "conflicts=" \
        || { rm -rf "$CC_WORK"; cc_unlock; return 1; }
    # ARM before any change. A failure to arm aborts with nothing changed.
    if ! systemd-run --quiet --unit="nftban-commit-rollback-${id}" --on-active="${grace}s" \
            --timer-property=AccuracySec=1s --description="NFTBan commit-confirm rollback for apply ${id}" \
            "$CC_NFTBAN_BIN" firewall rollback "$id" --auto >/dev/null 2>&1; then
        echo "REFUSED: the automatic rollback could not be armed (systemd-run failed); nothing was changed." >&2
        rm -f "$CC_RECORD"; rm -rf "$CC_WORK"; cc_unlock; return 1
    fi
    cc_unlock
    export CC_APPLY_ID="$id"
    return 0
}

# Called by the rebuild after the candidate LOADED: keep the candidate projection
# (never published here) and its hash, so confirm can commit it and a crash can be
# decided from durable facts.
cc_apply_loaded() {  # loaded_ruleset
    local loaded="$1"
    [[ -n "${CC_APPLY_ID:-}" ]] || return 1
    # shellcheck source=/dev/null
    declare -F nftban_boot_projection_publish >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/boot_projection.sh"
    nftban_boot_projection_publish "$loaded" "$CC_WORK/candidate-projection.nft" >/dev/null 2>&1 || return 1
    cp -f "$loaded" "$CC_WORK/candidate-ruleset.nft" || return 1
    cc_lock || return 1
    cc_set candidate_projection_sha "$(cc_sha "$CC_WORK/candidate-projection.nft")"
    cc_unlock
    echo ""
    echo "  Applied as a PENDING change (apply ID ${CC_APPLY_ID})."
    echo "  It is rolled back automatically at $(cc_utc "$(cc_get deadline_epoch)") unless you confirm:"
    echo "      nftban firewall confirm ${CC_APPLY_ID}"
    echo "  Test access with a NEW connection before confirming. The boot projection is NOT updated until confirm."
}

# The candidate failed to load (nft -f is atomic: nothing changed). Disarm and forget.
cc_apply_abort() {
    [[ -n "${CC_APPLY_ID:-}" ]] || return 0
    systemctl stop "nftban-commit-rollback-${CC_APPLY_ID}.timer" >/dev/null 2>&1 || true
    cc_lock && { rm -f "$CC_RECORD"; rm -rf "$CC_WORK"; cc_unlock; }
    return 0
}

# Promote the confirmed candidate to the applied baseline.
cc_promote_candidate() {
    cc_record_applied_baseline "$CC_WORK/candidate-ruleset.nft" "$CC_WORK/candidate-config"
}

# Commit point helper: atomic rename of the candidate projection onto the live path.
cc_commit_projection() {
    local proj="${CC_CONFIG}/generated/nftban-boot.nft" tmp
    tmp="${proj}.confirm.$$"
    cp -f "$CC_WORK/candidate-projection.nft" "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$proj" || { rm -f "$tmp"; return 1; }
    command -v restorecon >/dev/null 2>&1 && restorecon -F "$proj" 2>/dev/null
    return 0
}

cc_projection_is_candidate() {
    local want; want="$(cc_get candidate_projection_sha)"
    [[ -n "$want" && "$(cc_sha "${CC_CONFIG}/generated/nftban-boot.nft")" == "$want" ]]
}

cc_finish_confirm() {  # (lock held)
    cc_set status confirmed
    cc_set at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cc_promote_candidate || echo "WARNING: confirmed, but the applied baseline could not be updated" >&2
    systemctl stop "nftban-commit-rollback-$(cc_get apply_id).timer" >/dev/null 2>&1 || true
}

# nftban firewall confirm [apply_id]
cc_confirm() {
    local want="${1:-}" id now
    cc_lock || { echo "ERROR: commit-confirm lock busy" >&2; return 1; }
    id="$(cc_get apply_id)"
    if [[ "$(cc_status)" != "pending" ]]; then
        echo "Nothing to confirm (last apply ${id:-none}: $(cc_status || echo none))." >&2; cc_unlock; return 1
    fi
    if [[ -n "$want" && "$want" != "$id" ]]; then
        echo "REFUSED: apply ID $want is not the pending apply ($id)." >&2; cc_unlock; return 1
    fi
    now=$(cc_now)
    local dl; dl="$(cc_get deadline_epoch)"; [[ "$dl" =~ ^[0-9]+$ ]] || dl=0
    if (( now >= ${dl:-0} )); then
        echo "REFUSED: the confirm deadline of apply $id has passed; the automatic rollback is due." >&2; cc_unlock; return 1
    fi
    # Proof of the administrator's confirm FOR THIS APPLY ID, recorded before the commit
    # point. A boot projection equal to the candidate is not proof on its own: the
    # candidate projection can be byte-identical to the baseline's.
    if ! cc_set confirm_requested "$id"; then
        echo "CONFIRM FAILED: the confirm could not be recorded. Apply $id is STILL PENDING." >&2
        cc_unlock; return 1
    fi
    # Commit point, while the rollback is still armed.
    if ! cc_commit_projection; then
        cc_set confirm_requested "" || true
        echo "CONFIRM FAILED: the boot projection could not be published. Apply $id is STILL PENDING;" >&2
        echo "  the automatic rollback stays armed and runs at $(cc_utc "$(cc_get deadline_epoch)")." >&2
        cc_unlock; return 1
    fi
    cc_finish_confirm
    cc_unlock
    echo "✅ Apply $id CONFIRMED: rules kept and made persistent (boot projection updated)."
}

# Restore the change set from the applied baseline, never overwriting a file edited
# again after the apply. Prints conflicts (comma-separated) on stdout.
cc_restore_changeset() {
    local path base cand cur conflicts=""
    while IFS=$'\t' read -r path base cand; do
        [[ -n "$path" ]] || continue
        local live="${CC_CONFIG}/${path#./}"
        cur=MISSING; [[ -f "$live" ]] && cur="$(cc_sha "$live")"
        [[ "$cur" == "$base" ]] && continue          # already the baseline (e.g. resolved by the operator)
        if [[ "$cur" != "$cand" ]]; then
            conflicts="${conflicts:+$conflicts,}${path#./}"; continue
        fi
        if [[ "$base" == "MISSING" ]]; then
            rm -f "$live"
        else
            mkdir -p "$(dirname "$live")" && cp -pf "$CC_BASE/config/${path#./}" "$live"
        fi
    done < "$CC_WORK/changeset"
    printf '%s' "$conflicts"
}

# nftban firewall rollback <apply_id> [--auto|--boot]
cc_rollback() {
    local id="${1:-}" mode="${2:-manual}" rec_id st conflicts tx err tables
    cc_lock || { echo "ERROR: commit-confirm lock busy" >&2; return 1; }
    rec_id="$(cc_get apply_id)"; st="$(cc_status)"
    if [[ -z "$rec_id" || ( -n "$id" && "$id" != "$rec_id" ) ]]; then
        echo "Nothing to roll back for apply ${id:-?} (current record: ${rec_id:-none})." >&2; cc_unlock; return 0
    fi
    case "$st" in
        confirmed|rolled-back|abandoned) echo "Apply $rec_id is already $st; nothing to do."; cc_unlock; return 0 ;;
        pending|rollback-failed) : ;;
        *) echo "Unknown commit-confirm state '$st'; nothing done." >&2; cc_unlock; return 1 ;;
    esac
    # A crash after confirm's commit point: complete the confirm, never roll back. Both
    # are required: the recorded confirm for THIS apply ID and the candidate projection.
    if [[ "$st" == "pending" && "$(cc_get confirm_requested)" == "$rec_id" ]] && cc_projection_is_candidate; then
        cc_finish_confirm; cc_unlock
        echo "Apply $rec_id had passed its commit point (confirm recorded, boot projection = candidate): confirm completed."
        return 0
    fi
    # 1. Config: only the change set, never overwriting a later independent edit.
    conflicts="$(cc_restore_changeset)"
    # 2. Kernel (not at boot: the old projection is what loaded): ONE transaction,
    #    NFTBan tables only; foreign tables are never part of it.
    if [[ "$mode" != "--boot" ]]; then
        tx=$(mktemp) || { cc_unlock; return 1; }
        { printf 'add table ip nftban\ndelete table ip nftban\nadd table ip6 nftban\ndelete table ip6 nftban\n'
          cat "$CC_WORK/kernel-before.nft"; } > "$tx"
        if ! err=$(nft -f "$tx" 2>&1); then
            rm -f "$tx"
            # Owner D10: KEEP the current kernel state + ALARM. Never auto-delete protection.
            cc_set status rollback-failed
            cc_set error "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-500)"
            cc_set conflicts "$conflicts"
            cc_set at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            if tables=$(nft list tables 2>&1); then
                if grep -qxE 'table (ip|ip6) nftban' <<<"$tables"; then
                    cc_set kernel "candidate still active (rollback transaction rejected; kernel unchanged)"
                else
                    cc_set kernel "no NFTBan table present"
                fi
            else
                cc_set kernel "UNKNOWN (kernel tables could not be read)"
            fi
            : > "$CC_FAILED_MARK"
            cc_unlock
            local msg="NFTBan commit-confirm ROLLBACK FAILED for apply $rec_id: $err"
            logger -t nftban -p auth.crit "$msg" 2>/dev/null || true
            command -v nftban_send_alert >/dev/null 2>&1 && nftban_send_alert "commit-confirm rollback failed" "$msg" 2>/dev/null || true
            echo "❌ $msg" >&2
            echo "   Kernel: $(cc_get kernel). Baseline, snapshots and this record are KEPT." >&2
            echo "   Recover: retry 'nftban firewall rollback $rec_id'; or from the console 'nftban disable all --flush-rules';" >&2
            echo "   or boot once with the kernel parameter nftban=disabled." >&2
            return 1
        fi
        rm -f "$tx"
    fi
    # 3. Projection: it was never published; make sure it is the baseline's.
    if [[ -f "$CC_BASE/projection.nft" ]] && [[ "$(cc_sha "${CC_CONFIG}/generated/nftban-boot.nft")" != "$(cc_sha "$CC_BASE/projection.nft")" ]]; then
        cp -f "$CC_BASE/projection.nft" "${CC_CONFIG}/generated/nftban-boot.nft.rb.$$" \
          && mv -f "${CC_CONFIG}/generated/nftban-boot.nft.rb.$$" "${CC_CONFIG}/generated/nftban-boot.nft"
    fi
    systemctl stop "nftban-commit-rollback-${rec_id}.timer" >/dev/null 2>&1 || true
    # Owner 2026-10-07: an UNRESOLVED conflict means the rollback could not restore the
    # whole change set. The later edit is kept (never overwritten), but the writers that
    # would apply it (nftband sync, maintenance, autoheal rebuild) must not resume on
    # their own: this is the D10 hold. The kernel is already the baseline. The operator
    # resolves the file(s) and retries the rollback, or accepts them with --abandon.
    if [[ -n "$conflicts" ]]; then
        cc_set status rollback-failed
        cc_set error "unresolved conflicts: files edited after the apply: ${conflicts//,/, }"
        cc_set conflicts "$conflicts"
        cc_set kernel "baseline restored (NFTBan tables of the applied baseline)"
        cc_set at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        : > "$CC_FAILED_MARK"
        cc_unlock
        local msg="NFTBan commit-confirm rollback of apply $rec_id INCOMPLETE: kernel restored to the baseline, but these files were edited after the apply and were NOT restored: ${conflicts//,/, }. NFTBan writers are held."
        logger -t nftban -p auth.crit "$msg" 2>/dev/null || true
        echo "⚠️  $msg" >&2
        echo "   Resolve: bring each file back to what you want, then 'nftban firewall rollback $rec_id' (a file equal to the baseline is no longer a conflict)," >&2
        echo "   or accept the files as they are now: 'nftban firewall rollback --abandon'." >&2
        return 1
    fi
    cc_set status rolled-back
    cc_set conflicts ""
    cc_set at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rm -f "$CC_FAILED_MARK"
    cc_unlock
    # 4. The daemon re-reads the restored configuration (not at boot: it starts after us).
    if [[ "$mode" != "--boot" ]] && systemctl is-active --quiet nftband.service 2>/dev/null; then
        systemctl restart nftband.service >/dev/null 2>&1 || true
    fi
    echo "↩️  Apply $rec_id ROLLED BACK to the applied baseline."
    return 0
}

# nftban-commit-confirm-boot.service: decide a pending apply BEFORE the daemon/timers.
# Owner D10: while a rollback has FAILED, every boot raises the alarm again (the
# other NFTBan units are held back by their condition, so this is the one that speaks).
cc_boot() {
    [[ -r "$CC_RECORD" ]] || return 0
    if [[ -e "$CC_FAILED_MARK" ]]; then
        local msg
        msg="NFTBan commit-confirm ROLLBACK FAILED for apply $(cc_get apply_id) (since $(cc_get at)); kernel: $(cc_get kernel). NFTBan units are held until recovery."
        logger -t nftban -p auth.crit "$msg" 2>/dev/null || true
        echo "❌ $msg" >&2
        cc_refuse_if_rollback_failed "boot" || true
        return 0
    fi
    [[ "$(cc_status)" == "pending" ]] || return 0
    cc_rollback "$(cc_get apply_id)" --boot
}

# Explicit abandon of a failed rollback (operator decision after recovery).
cc_abandon() {
    local id="${1:-}"
    cc_lock || return 1
    if [[ "$(cc_status)" != "rollback-failed" || ( -n "$id" && "$id" != "$(cc_get apply_id)" ) ]]; then
        echo "Nothing to abandon." >&2; cc_unlock; return 1
    fi
    cc_set status abandoned; cc_set at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rm -f "$CC_FAILED_MARK"; cc_unlock
    echo "Failed rollback of apply $(cc_get apply_id) abandoned by the operator; normal operation may resume."
}
