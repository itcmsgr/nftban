#!/bin/sh
# =============================================================================
# NFTBan - proven ownership of immutable flags + filesystem-restriction preflight
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_immutable_owned"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-01"
# meta:description="POSIX sh library (v1.234, PR #1439). One implementation, used by the CLI update/repair/rollback paths (sourced) and inlined into the DEB preinst/prerm/postinst and the RPM pretrans/preun/posttrans by build/generate-immutable-owned-blocks.sh. NFTBan only removes or restores an immutable flag whose ownership is PROVEN: a record entry written when NFTBan itself set or cleared the flag, matched by inode AND ctime (ctime changes on any later attribute change), or for flags set by NFTBan before v1.234 an installer.log 'set immutable' line whose timestamp equals the file's ctime. A path name never proves ownership. The preflight reports, before any change, every package destination that cannot be modified and why: IMMUTABLE, APPEND-ONLY, READ-ONLY mount, or WRITE-DENIED (permission/ACL/SELinux/AppArmor; never reported as immutable). Inspection that cannot run is UNMEASURED."
# meta:inventory.files="/var/lib/nftban/state/immutable-owned, /var/log/nftban/installer.log (read)"
# meta:inventory.binaries="lsattr,chattr,stat,date,findmnt,awk,sort,xargs"
# meta:inventory.env_vars="NFTBAN_IMMUT_RECORD,NFTBAN_IMMUT_INSTALLER_LOG,NFTBAN_IMMUT_CANDIDATES,NFTBAN_IMMUT_FIXED_DIRS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# Record format (/var/lib/nftban/state/immutable-owned), one line per file:
#   <path> TAB <inode> TAB <ctime epoch s> TAB <locked|unlocked> TAB <written at epoch s>
#   locked   = NFTBan set +i; inode/ctime captured right after.
#   unlocked = NFTBan removed its own +i; inode/ctime captured right after.
# Written by: Go validate.SetImmutableFlags (locked) and the functions below.
#
# Candidates: the files NFTBan applies its +i policy to
# (build/+i-lifecycle-matrix.yaml protected_files):
#   /etc/nftban/nftban.conf /usr/lib/nftban/lib/nft_schema.sh
# Being a candidate is NOT ownership. Ownership is proven per flag, per file.

_nftban_immut_record() { printf '%s' "${NFTBAN_IMMUT_RECORD:-/var/lib/nftban/state/immutable-owned}"; }
_nftban_immut_ilog() { printf '%s' "${NFTBAN_IMMUT_INSTALLER_LOG:-/var/log/nftban/installer.log}"; }
_nftban_immut_candidates() {
    printf '%s\n' ${NFTBAN_IMMUT_CANDIDATES:-/etc/nftban/nftban.conf /usr/lib/nftban/lib/nft_schema.sh}
}

# _nftban_immut_has_i PATH -> 0 has +i, 1 no +i, 2 UNMEASURED (lsattr missing/unsupported)
_nftban_immut_has_i() {
    _hi_a=$(lsattr -d -- "$1" 2>/dev/null) || return 2
    _hi_a=${_hi_a%% *}
    case "$_hi_a" in *i*) return 0 ;; esac
    return 1
}

# _nftban_immut_inoct PATH -> prints "<inode> <ctime epoch s>"
_nftban_immut_inoct() { stat -c '%i %Z' -- "$1" 2>/dev/null; }

# _nftban_immut_proven PATH STATE -> 0 only when ownership is PROVEN. Accepted evidence:
#   1. record entry for PATH in STATE whose inode AND ctime equal the file's current
#      inode and ctime (ctime moves on every later attribute change; a replaced file
#      has a new inode);
#   2. STATE=locked only, no record entry for PATH at all (pre-v1.234 flag): the LAST
#      "[DEBUG] set immutable: PATH" line in installer.log (exact path) is timestamped
#      at exactly the file's ctime second. An older matching line, a line one second
#      off, or a line for another path is not proof. Pre-v1.234 lines carry no inode,
#      so an administrator action in that same second is indistinguishable (residual).
#   Everything else -> not proven (treated as administrator-owned).
_nftban_immut_proven() {
    _pv_p=$1; _pv_st=$2
    _pv_ic=$(_nftban_immut_inoct "$_pv_p") || return 1
    [ -n "$_pv_ic" ] || return 1
    _pv_ino=${_pv_ic% *}; _pv_ct=${_pv_ic#* }
    _pv_rec=$(_nftban_immut_record)
    if [ -f "$_pv_rec" ]; then
        if awk -F'\t' -v p="$_pv_p" -v i="$_pv_ino" -v c="$_pv_ct" -v s="$_pv_st" \
                '$1==p && $2==i && $3==c && $4==s {f=1} END {exit f ? 0 : 1}' "$_pv_rec"; then
            return 0
        fi
        # the record knows this path: its entry is the only admissible evidence
        if awk -F'\t' -v p="$_pv_p" '$1==p {f=1} END {exit f ? 0 : 1}' "$_pv_rec"; then
            return 1
        fi
    fi
    [ "$_pv_st" = locked ] || return 1
    _pv_log=$(_nftban_immut_ilog)
    [ -f "$_pv_log" ] || return 1
    _pv_last=$(awk -v p="$_pv_p" 'index($0, " [DEBUG] set immutable: ") {
            s=$0; sub(/^.* \[DEBUG\] set immutable: /, "", s); sub(/[ \r]+$/, "", s)
            if (s == p) last=$1 } END {print last}' "$_pv_log" 2>/dev/null)
    [ -n "$_pv_last" ] || return 1
    _pv_ts=$(date -u -d "@$_pv_ct" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 1
    [ "$_pv_last" = "$_pv_ts" ]
}

# _nftban_immut_record_set PATH STATE [WRITTEN_AT] -> replace PATH's record line with
# the current inode+ctime and STATE. Never fatal for the caller.
_nftban_immut_record_set() {
    _rs_ic=$(_nftban_immut_inoct "$1") || return 1
    [ -n "$_rs_ic" ] || return 1
    _rs_rec=$(_nftban_immut_record)
    _rs_at=${3:-$(date -u +%s)}
    mkdir -p "${_rs_rec%/*}" 2>/dev/null || true
    _rs_tmp="$_rs_rec.tmp.$$"
    {
        if [ -f "$_rs_rec" ]; then awk -F'\t' -v p="$1" '$1!=p' "$_rs_rec"; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "${_rs_ic% *}" "${_rs_ic#* }" "$2" "$_rs_at"
    } > "$_rs_tmp" 2>/dev/null && mv -f "$_rs_tmp" "$_rs_rec" 2>/dev/null
}

# nftban_immut_unlock_owned -> remove NFTBan's own PROVEN +i from the candidates.
# Prints one line per candidate that carries +i: "UNLOCKED <path>" or
# "NOT_PROVEN <path>" (left untouched: treated as administrator-owned). Always rc 0;
# refusing is the preflight's job.
nftban_immut_unlock_owned() {
    for _uo_f in $(_nftban_immut_candidates); do
        [ -f "$_uo_f" ] && [ ! -L "$_uo_f" ] || continue
        _uo_r=0; _nftban_immut_has_i "$_uo_f" || _uo_r=$?
        [ "$_uo_r" -eq 0 ] || continue
        if _nftban_immut_proven "$_uo_f" locked && chattr -i -- "$_uo_f" 2>/dev/null; then
            _nftban_immut_record_set "$_uo_f" unlocked || true
            printf 'UNLOCKED %s\n' "$_uo_f"
        else
            printf 'NOT_PROVEN %s\n' "$_uo_f"
        fi
    done
    return 0
}

# nftban_immut_relock_owned -> put back +i ONLY where the record proves NFTBan removed
# it and nothing changed the file since (same inode and ctime). Prints per candidate:
#   RELOCKED <path>        protection restored
#   RELOCK_FAILED <path>   proven NFTBan-unlocked, but chattr +i failed
#   NOT_RELOCKED <path>    NFTBan unlocked it, but the file changed since (new inode
#                          or ctime) - not restored automatically; reported.
nftban_immut_relock_owned() {
    _ro_rec=$(_nftban_immut_record)
    for _ro_f in $(_nftban_immut_candidates); do
        [ -f "$_ro_f" ] && [ ! -L "$_ro_f" ] || continue
        _ro_r=0; _nftban_immut_has_i "$_ro_f" || _ro_r=$?
        [ "$_ro_r" -eq 1 ] || continue
        if _nftban_immut_proven "$_ro_f" unlocked; then
            if chattr +i -- "$_ro_f" 2>/dev/null; then
                _nftban_immut_record_set "$_ro_f" locked || true
                printf 'RELOCKED %s\n' "$_ro_f"
            else
                printf 'RELOCK_FAILED %s\n' "$_ro_f"
            fi
        elif [ -f "$_ro_rec" ] && awk -F'\t' -v p="$_ro_f" '$1==p && $4=="unlocked" {f=1} END {exit f ? 0 : 1}' "$_ro_rec"; then
            printf 'NOT_RELOCKED %s\n' "$_ro_f"
        fi
    done
    return 0
}

# nftban_immut_txn_restore MARKER_EPOCH -> RPM transition repair, run in posttrans.
# On upgrade RPM runs the OLD package's preun AFTER the new installer set +i; an old
# preun (v1.233.x and earlier) strips +i unconditionally. Restore +i only when the record
# shows NFTBan set it IN THIS TRANSACTION (written at >= MARKER_EPOCH, written by the
# pretrans of this transaction), on the same inode, and the flag is now absent.
nftban_immut_txn_restore() {
    _tr_m=$1
    _tr_rec=$(_nftban_immut_record)
    [ -n "$_tr_m" ] && [ -f "$_tr_rec" ] || return 0
    for _tr_f in $(_nftban_immut_candidates); do
        [ -f "$_tr_f" ] && [ ! -L "$_tr_f" ] || continue
        _tr_r=0; _nftban_immut_has_i "$_tr_f" || _tr_r=$?
        [ "$_tr_r" -eq 1 ] || continue
        _tr_ic=$(_nftban_immut_inoct "$_tr_f") || continue
        if awk -F'\t' -v p="$_tr_f" -v i="${_tr_ic% *}" -v m="$_tr_m" \
                '$1==p && $2==i && $4=="locked" && $5+0 >= m+0 {f=1} END {exit f ? 0 : 1}' "$_tr_rec" \
           && chattr +i -- "$_tr_f" 2>/dev/null; then
            _nftban_immut_record_set "$_tr_f" locked || true
            printf 'RESTORED %s\n' "$_tr_f"
        fi
    done
    return 0
}

# Destination directories of a package install that may exist before NFTBan does.
_nftban_immut_fixed_dirs() {
    if [ -n "${NFTBAN_IMMUT_FIXED_DIRS:-}" ]; then printf '%s\n' $NFTBAN_IMMUT_FIXED_DIRS; return 0; fi
    printf '%s\n' /usr/sbin /usr/lib/systemd/system /usr/lib/tmpfiles.d /etc/sysctl.d \
        /etc/logrotate.d /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d /etc/apparmor.d \
        /usr/share/bash-completion/completions /usr/share/licenses /usr/share/doc \
        /usr/lib/nftban /usr/lib/nftban/bin /usr/lib/nftban/lib /usr/share/nftban /etc/nftban
}

# nftban_fs_preflight CONFFILES_FILE < payload-paths
#   Read-only. For every payload path: an existing file is checked for its own flags
#   (replace/delete), its parent directory (and, for a path that does not exist yet,
#   the nearest existing ancestor) is checked for flags, mount and write access.
#   Prints:  BLOCKED <IMMUTABLE|APPEND-ONLY|READ-ONLY|WRITE-DENIED> <file|dir> <path> (<detail>)
#            WARN <...>        UNMEASURED <...>
#   rc 1 when anything is BLOCKED, else 0. A flag on a file NFTBan can PROVE it set is
#   not blocking (it is unlocked separately); a flag on a conffile is a WARN (the
#   package manager leaves an unchanged conffile in place).
nftban_fs_preflight() {
    _pf_conff=${1:-/dev/null}
    _pf_tmp=$(mktemp -d 2>/dev/null) || { printf 'UNMEASURED preflight: cannot create a temporary directory\n'; return 0; }
    _pf_rc=0
    while IFS= read -r _pf_p; do
        case "$_pf_p" in /?*) ;; *) continue ;; esac
        _pf_p=${_pf_p%/}
        if [ -L "$_pf_p" ]; then
            :   # flags do not apply to a symlink itself
        elif [ -d "$_pf_p" ]; then
            printf 'dir\t%s\n' "$_pf_p"
        elif [ -e "$_pf_p" ]; then
            printf 'file\t%s\n' "$_pf_p"
        fi
        _pf_d=${_pf_p%/*}; [ -n "$_pf_d" ] || _pf_d=/
        while [ "$_pf_d" != / ] && [ ! -e "$_pf_d" ]; do _pf_d=${_pf_d%/*}; [ -n "$_pf_d" ] || _pf_d=/; done
        if [ -d "$_pf_d" ] && [ ! -L "$_pf_d" ]; then printf 'dir\t%s\n' "$_pf_d"; fi
    done | sort -u > "$_pf_tmp/targets"

    if [ ! -s "$_pf_tmp/targets" ]; then
        printf 'UNMEASURED preflight: no package paths resolved\n'
        rm -rf "$_pf_tmp"; return 0
    fi

    # 1. attribute flags (one lsattr batch)
    if command -v lsattr >/dev/null 2>&1; then
        cut -f2 "$_pf_tmp/targets" | xargs -d '\n' -r lsattr -d -- > "$_pf_tmp/attrs" 2> "$_pf_tmp/attrs.err" || true
        awk 'NR==FNR {t=index($0, "\t"); k[substr($0, t+1)]=substr($0, 1, t-1); next}
            { s=index($0, " "); a=substr($0, 1, s-1); p=substr($0, s+1); if ((p in k) && a ~ /[ia]/) print k[p] "\t" a "\t" p }' \
            "$_pf_tmp/targets" "$_pf_tmp/attrs" > "$_pf_tmp/flagged"
        while IFS= read -r _pf_p; do
            printf 'UNMEASURED %s\n' "${_pf_p#lsattr: }"
        done < "$_pf_tmp/attrs.err"
        while IFS="	" read -r _pf_kind _pf_attrs _pf_path; do
            _pf_what=IMMUTABLE
            case "$_pf_attrs" in *i*) ;; *) _pf_what=APPEND-ONLY ;; esac
            if [ "$_pf_kind" = file ] && [ "$_pf_what" = IMMUTABLE ] && _nftban_immut_proven "$_pf_path" locked; then
                continue   # NFTBan's own proven flag: unlocked by nftban_immut_unlock_owned
            fi
            if [ "$_pf_kind" = file ] && grep -qxF -- "$_pf_path" "$_pf_conff" 2>/dev/null; then
                printf 'WARN %s conffile %s (%s): blocks only if the new version changes this file\n' "$_pf_what" "$_pf_path" "$_pf_attrs"
                continue
            fi
            printf 'BLOCKED %s %s %s (%s; not set by NFTBan, or ownership not provable)\n' "$_pf_what" "$_pf_kind" "$_pf_path" "$_pf_attrs"
            _pf_rc=1
            [ "$_pf_kind" = dir ] && printf '%s\n' "$_pf_path" >> "$_pf_tmp/dir_reported"
        done < "$_pf_tmp/flagged"
    else
        printf 'UNMEASURED attribute flags on %s paths (lsattr not available)\n' "$(wc -l < "$_pf_tmp/targets" | tr -d ' ')"
    fi

    # 2. read-only mounts and 3. write access, per directory
    # 3. write access asks the KERNEL: the shell builtin `[ -w ]` is faccessat(2)
    # with AT_EACCESS (dash: faccessat2, bash: eaccess), which applies the caller's
    # real privileges (root CAP_DAC_OVERRIDE, ACLs, MAC). v1.235: an external test
    # binary must never decide this. uutils test (rust-coreutils 0.8.0, /usr/bin/test
    # on Ubuntu 26.04) never calls access(2); it does mode-bit arithmetic from statx and
    # ignores root privilege, so it answered "not writable" for 0750 nftban:nftban dirs
    # that root could write (measured on a production host: create+remove succeeded,
    # gnutest and the builtins answered writable) and the upgrade was falsely refused.
    # (BUG-PREFLIGHT-WRITE-DENIED-FALSE-ON-UBUNTU-26-UUTILS-TEST)
    : > "$_pf_tmp/ro_seen"
    awk -F'\t' '$1=="dir" {print $2}' "$_pf_tmp/targets" > "$_pf_tmp/dirs"
    while IFS= read -r _pf_d; do
        grep -qxF -- "$_pf_d" "$_pf_tmp/dir_reported" 2>/dev/null && continue
        if command -v findmnt >/dev/null 2>&1; then
            _pf_tgt=""; _pf_opts=""
            read -r _pf_tgt _pf_opts <<EOF_FINDMNT
$(findmnt -no TARGET,OPTIONS -T "$_pf_d" 2>/dev/null)
EOF_FINDMNT
            if [ -z "$_pf_tgt" ]; then
                printf 'UNMEASURED mount options for %s\n' "$_pf_d"
            else
                case ",$_pf_opts," in
                    *,ro,*)
                        if ! grep -qxF -- "$_pf_tgt" "$_pf_tmp/ro_seen"; then
                            printf '%s\n' "$_pf_tgt" >> "$_pf_tmp/ro_seen"
                            printf 'BLOCKED READ-ONLY dir %s (mount %s: %s)\n' "$_pf_d" "$_pf_tgt" "$_pf_opts"
                            _pf_rc=1
                        fi
                        continue ;;
                esac
            fi
        else
            printf 'UNMEASURED mount options for %s (findmnt not available)\n' "$_pf_d"
        fi
        if [ ! -w "$_pf_d" ]; then
            printf 'BLOCKED WRITE-DENIED dir %s (no immutable flag and not a read-only mount: permission, ACL or SELinux/AppArmor policy; check the audit log)\n' "$_pf_d"
            _pf_rc=1
        fi
    done < "$_pf_tmp/dirs"

    rm -rf "$_pf_tmp"
    return "$_pf_rc"
}

# nftban_fs_preflight_report -> human guidance after a refusal (stderr).
nftban_fs_preflight_report() {
    {
        printf 'nftban: Nothing was changed. NFTBan never removes a protection it cannot prove it set itself,\n'
        printf 'nftban: and never remounts a filesystem. Treat each path above as protected by its administrator.\n'
        printf 'nftban: IMMUTABLE/APPEND-ONLY: only the administrator responsible for that protection can decide to lift it.\n'
        printf 'nftban:   That is a deliberate removal of one specific protection on one named path (e.g. chattr -i <path>),\n'
        printf 'nftban:   followed by this operation and by re-applying the protection. It is not a repair step.\n'
        printf 'nftban:   An earlier NFTBan version may have set +i on nftban.conf / nft_schema.sh; if installer.log no longer\n'
        printf 'nftban:   proves it, decide yourself whether that flag is NFTBan'\''s before removing it.\n'
        printf 'nftban: READ-ONLY: retry while the filesystem is writable. WRITE-DENIED: check permissions/ACLs and the audit log.\n'
        printf 'nftban: Inspect: lsattr -d <path>   findmnt -T <path>   ausearch -m AVC -ts recent\n'
    } >&2
}

# Package entry points ---------------------------------------------------------
# nftban_immut_pkg_preflight deb|rpm -> preflight over the INSTALLED manifest (upgrade)
# plus the fixed destination directories (fresh install). rc 1 = refuse.
nftban_immut_pkg_preflight() {
    _pp_tmp=$(mktemp 2>/dev/null) || return 0
    case "$1" in
        deb) dpkg-query -W -f='${Conffiles}\n' nftban-core 2>/dev/null | awk 'NF {print $1}' > "$_pp_tmp" || true ;;
        rpm) rpm -qc nftban-core 2>/dev/null > "$_pp_tmp" || true ;;
    esac
    _pp_rc=0
    _pp_out=$( {
        case "$1" in
            deb) dpkg-query -L nftban-core 2>/dev/null || true ;;
            rpm) rpm -ql nftban-core 2>/dev/null | grep '^/' || true ;;
        esac
        _nftban_immut_fixed_dirs
    } | nftban_fs_preflight "$_pp_tmp") || _pp_rc=$?
    rm -f "$_pp_tmp"
    [ -n "$_pp_out" ] && printf '%s\n' "$_pp_out" | sed 's/^/nftban: /' >&2
    if [ "$_pp_rc" -ne 0 ]; then
        nftban_fs_preflight_report
        return 1
    fi
    return 0
}
