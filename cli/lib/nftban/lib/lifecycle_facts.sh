#!/usr/bin/env bash
# =============================================================================
# NFTBan - lifecycle facts for status / health (v1.235, row 486 contract D8)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="lifecycle_facts"
# meta:type="lib"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="Collects and renders the four separate lifecycle facts that status and health must show (CLI_AUDIT_V1235/ROW486_BEHAVIOUR_CONTRACT_V1235.md, 'Status / health must show four separate facts'): STORED choice, APPLIED now, ON REBOOT, RECOVERY; plus the per-boot emergency bypass and the disable unit record. A mismatch is a named EXPECTED or DIVERGENCE line; an unread fact is UNKNOWN, never OK/DISABLED/0. Reads only; never changes state."
# meta:inventory.files="/var/lib/nftban/state/applied/meta,/run/nftban/boot-bypass.state,/var/lib/nftban/state/commit-confirm.state,/etc/nftban/conf.d/services.conf,/etc/nftban/generated/nftban-boot.nft,/var/lib/nftban/state/disable-units.state,/etc/sysconfig/nftables.conf,/etc/nftables.conf"
# meta:inventory.binaries="nft,systemctl,grep"
# meta:inventory.env_vars="NFTBAN_STATE_DIR,NFTBAN_RUN_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/services.conf"
# meta:inventory.systemd_units="nftables.service,nftband.service,nftban-*.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root for a complete read; partial reads render UNKNOWN"
# =============================================================================
# Authorities this file READS (it re-implements none of them):
#   nftban_master_switch_on        lib/service_control.sh   rc 0 on, 1 off
#   nftban_emergency_bypass_active lib/service_control.sh   rc 0 active, 1 inactive
#   nftban_boot_projection_state   lib/boot_projection.sh   prints active|inert|missing|unknown
# Each is loaded on demand from ${NFTBAN_LIB_DIR}/lib when not already defined; when an
# authority cannot be loaded, its fact is UNKNOWN (never guessed).
# =============================================================================

[[ -n "${_NFTBAN_LIFECYCLE_FACTS_LOADED:-}" ]] && return 0
_NFTBAN_LIFECYCLE_FACTS_LOADED=1

# The installer's include directive (internal/installer/render/sysconf.go IncludeDirective).
_NFTBAN_LF_INCLUDE='include "/etc/nftban/generated/nftban-boot.nft"'

# _nftban_lf_rc <cmd...> -> echoes the command's rc (never aborts the caller)
_nftban_lf_rc() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# _nftban_lf_load_authorities: status and health do not source lib/service_control.sh
# or lib/boot_projection.sh themselves (status loads lib/nftban_service_control.sh, a
# different file). Load each authority on demand, as cmd_firewall.sh does: a lab3
# runtime pass (v1.235) read all three facts as UNKNOWN because nothing loaded them.
# A library that is absent or fails to load leaves its fact UNKNOWN.
_nftban_lf_load_authorities() {
    local lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib"
    if ! declare -F nftban_master_switch_on >/dev/null 2>&1 && [[ -r "$lib/service_control.sh" ]]; then
        # shellcheck source=/dev/null
        source "$lib/service_control.sh" 2>/dev/null || true
    fi
    if ! declare -F nftban_boot_projection_state >/dev/null 2>&1 && [[ -r "$lib/boot_projection.sh" ]]; then
        # shellcheck source=/dev/null
        source "$lib/boot_projection.sh" 2>/dev/null || true
    fi
    return 0
}

# nftban_lifecycle_collect: sets the LF_* globals and the LF_NOTES array.
nftban_lifecycle_collect() {
    local rc
    LF_NOTES=()
    _nftban_lf_load_authorities

    # --- STORED choice --------------------------------------------------------------
    LF_STORED=UNKNOWN
    if declare -F nftban_master_switch_on >/dev/null 2>&1; then
        rc="$(_nftban_lf_rc nftban_master_switch_on)"
        case "$rc" in 0) LF_STORED=enabled ;; 1) LF_STORED=disabled ;; esac
    fi

    # --- per-boot emergency bypass (contract §3/§6) ---------------------------------------
    # ACTIVE / DEGRADED (the backstop removed loaded NFTBan rules) / not present /
    # unit not enabled (would not act before the first load). The outcome comes from
    # /run/nftban/boot-bypass.state (per boot, tmpfs: written in early boot, before /var
    # may be mounted). Keys: outcome= primary|fallback-rename|created-inert|failed|
    # backstop-removed|backstop-failed|backstop-unknown, at=<UTC>, monotonic_us=, detail=.
    LF_BYPASS=UNKNOWN; LF_BYPASS_UNIT=UNKNOWN
    local bs="${NFTBAN_RUN_DIR:-/run/nftban}/boot-bypass.state" b_out="" b_at="" b_mono="" b_det=""
    if [[ -r "$bs" ]]; then
        b_out="$(grep -m1 -E '^outcome=' "$bs" 2>/dev/null || true)"; b_out="${b_out#outcome=}"
        b_at="$(grep -m1 -E '^at=' "$bs" 2>/dev/null || true)"; b_at="${b_at#at=}"
        b_mono="$(grep -m1 -E '^monotonic_us=' "$bs" 2>/dev/null || true)"; b_mono="${b_mono#monotonic_us=}"
        b_det="$(grep -m1 -E '^detail=' "$bs" 2>/dev/null || true)"; b_det="${b_det#detail=}"
    fi
    LF_BYPASS_UNIT="$(systemctl is-enabled nftban-boot-bypass.service 2>/dev/null || true)"; LF_BYPASS_UNIT="${LF_BYPASS_UNIT:-UNKNOWN}"
    if declare -F nftban_emergency_bypass_active >/dev/null 2>&1; then
        rc="$(_nftban_lf_rc nftban_emergency_bypass_active)"
        case "$rc" in
            0) # GUARANTEE MET = outcome primary|fallback-rename|created-inert (the
               # authority above already confirmed nftban=disabled on /proc/cmdline).
               local _when="${b_at:-UNKNOWN time}"
               [[ "$b_mono" =~ ^[0-9]+$ ]] && _when="${_when}, T+$(( b_mono / 1000000 ))s"
               case "$b_out" in
                   primary|fallback-rename|created-inert)
                       LF_BYPASS="ACTIVE (guarantee met: outcome=${b_out}${b_at:+ at $b_at})" ;;
                   backstop-removed)
                       LF_BYPASS="DEGRADED (not a successful bypass: NFTBan rules WERE loaded during this bypass boot and removed (at ${_when}))" ;;
                   backstop-failed)
                       LF_BYPASS="DEGRADED (not a successful bypass: NFTBan rules WERE loaded during this bypass boot and the delete FAILED: NFTBan rules may still be active (at ${_when}))" ;;
                   backstop-unknown)
                       LF_BYPASS="DEGRADED (not a successful bypass: NFTBan rules were loaded during this bypass boot; the backstop outcome is UNKNOWN (at ${_when}))" ;;
                   failed)
                       LF_BYPASS="DEGRADED (the primary bypass FAILED${b_det:+: $b_det} (at ${_when}))" ;;
                   "") LF_BYPASS="ACTIVE (outcome record absent: guarantee UNKNOWN)" ;;
                   *)  LF_BYPASS="ACTIVE (unrecognised outcome '${b_out}': guarantee UNKNOWN)" ;;
               esac ;;
            1) if [[ "$LF_BYPASS_UNIT" == enabled ]]; then LF_BYPASS="not present (bypass unit enabled)"
               elif [[ "$LF_BYPASS_UNIT" == UNKNOWN ]]; then LF_BYPASS="not present (bypass unit state UNKNOWN)"
               else LF_BYPASS="not present; bypass unit ${LF_BYPASS_UNIT}"; fi ;;
        esac
    fi

    # --- commit-confirm (contract §4/§6) --------------------------------------------------
    local cs="${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/commit-confirm.state" c_id="" c_dl="" c_st="" c_at="" now rem
    LF_CC_STATUS=""; LF_CC_CONFLICTS=""
    # Applied baseline: rebuild --confirm needs a recorded last-known-good.
    local am="${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/applied/meta" a_at=""
    if [[ ! -e "$am" ]]; then
        LF_BASELINE="no applied baseline (rebuild --confirm unavailable)"
    elif [[ ! -r "$am" ]]; then
        LF_BASELINE=UNKNOWN
    else
        a_at="$(grep -m1 -E '^at=' "$am" 2>/dev/null || true)"; a_at="${a_at#at=}"
        LF_BASELINE="applied baseline at ${a_at:-UNKNOWN time}"
    fi
    if [[ ! -e "$cs" ]]; then
        LF_CC="no apply awaiting confirmation (no record)"
    elif [[ ! -r "$cs" ]]; then
        LF_CC=UNKNOWN
    else
        c_id="$(grep -m1 -E '^apply_id=' "$cs" 2>/dev/null || true)"; c_id="${c_id#apply_id=}"
        c_dl="$(grep -m1 -E '^deadline_epoch=' "$cs" 2>/dev/null || true)"; c_dl="${c_dl#deadline_epoch=}"
        c_st="$(grep -m1 -E '^status=' "$cs" 2>/dev/null || true)"; c_st="${c_st#status=}"
        c_at="$(grep -m1 -E '^at=' "$cs" 2>/dev/null || true)"; c_at="${c_at#at=}"
        LF_CC_STATUS="$c_st"
        local c_cf=""
        c_cf="$(grep -m1 -E '^conflicts=' "$cs" 2>/dev/null || true)"; c_cf="${c_cf#conflicts=}"
        LF_CC_CONFLICTS="$c_cf"
        case "$c_st" in
            pending)
                if [[ "$c_dl" =~ ^[0-9]+$ ]]; then
                    now="$(date +%s)"; rem=$(( c_dl - now ))
                    LF_CC="PENDING apply ${c_id:-UNKNOWN}: deadline $(date -u -d "@$c_dl" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$c_dl") ($( (( rem >= 0 )) && echo "${rem}s remaining" || echo "passed $(( -rem ))s ago; rollback due")); confirm with: nftban firewall confirm ${c_id:-<apply_id>}"
                else
                    LF_CC="PENDING apply ${c_id:-UNKNOWN}: deadline UNKNOWN; confirm with: nftban firewall confirm ${c_id:-<apply_id>}"
                fi ;;
            confirmed|rolled-back|rollback-failed) LF_CC="last outcome: ${c_st}${c_at:+ at $c_at}${c_id:+ (apply $c_id)}" ;;
            # commit_confirm.sh `firewall rollback --abandon`: the operator gave up a
            # failed rollback; normal operation may resume. A last outcome, not a fault.
            abandoned) LF_CC="last outcome: abandoned (a failed rollback, abandoned by the operator)${c_at:+ at $c_at}${c_id:+ (apply $c_id)}" ;;
            *) LF_CC="UNKNOWN (unrecognised record status '${c_st}')" ;;
        esac
    fi

    # --- APPLIED now -------------------------------------------------------------------
    LF_TABLES=UNKNOWN
    local tl=""
    if command -v nft >/dev/null 2>&1 && tl="$(nft list tables 2>/dev/null)"; then
        local v4=no v6=no
        [[ $'\n'"$tl"$'\n' == *$'\n'"table ip nftban"$'\n'* ]] && v4=yes
        [[ $'\n'"$tl"$'\n' == *$'\n'"table ip6 nftban"$'\n'* ]] && v6=yes
        if [[ $v4 == yes && $v6 == yes ]]; then LF_TABLES=present
        elif [[ $v4 == no && $v6 == no ]]; then LF_TABLES=absent
        else LF_TABLES="partial (ip=$v4 ip6=$v6)"; fi
    fi
    LF_DAEMON="$(systemctl is-active nftband.service 2>/dev/null || true)"; LF_DAEMON="${LF_DAEMON:-UNKNOWN}"
    LF_TIMERS=UNKNOWN
    local tlist=""
    if tlist="$(systemctl list-units --type=timer --state=active --no-legend --plain 'nftban-*' 2>/dev/null)"; then
        LF_TIMERS="$(grep -c '\.timer' <<<"$tlist" || true)"
    fi

    # --- ON REBOOT ---------------------------------------------------------------------
    LF_NFTSVC="$(systemctl is-enabled nftables.service 2>/dev/null || true)"; LF_NFTSVC="${LF_NFTSVC:-UNKNOWN}"
    LF_INCLUDE=UNKNOWN
    local dc=""
    # NFTBAN_LF_DISTRO_CONFS: test-only override of the two distro locations.
    local -a _dcs=()
    IFS=' ' read -r -a _dcs <<<"${NFTBAN_LF_DISTRO_CONFS:-/etc/sysconfig/nftables.conf /etc/nftables.conf}"
    for dc in "${_dcs[@]}"; do
        [[ -e "$dc" ]] || continue
        if [[ ! -r "$dc" ]]; then LF_INCLUDE=UNKNOWN; break; fi
        if grep -qF -- "$_NFTBAN_LF_INCLUDE" "$dc" 2>/dev/null; then LF_INCLUDE=present; else LF_INCLUDE=absent; fi
        break
    done
    LF_PROJECTION=UNKNOWN
    if declare -F nftban_boot_projection_state >/dev/null 2>&1; then
        LF_PROJECTION="$(nftban_boot_projection_state 2>/dev/null || true)"
        case "$LF_PROJECTION" in active|inert|missing|unknown) ;; *) LF_PROJECTION=unknown ;; esac
        [[ "$LF_PROJECTION" == unknown ]] && LF_PROJECTION=UNKNOWN
    fi

    # --- RECOVERY (proven paths only; no "window" is claimed) -------------------------
    case "$LF_PROJECTION" in
        active) LF_RECOVERY="boot access = the SSH port(s) the projection opens, before the whitelist sync; console. NFTBAN_STARTUP_DELAY does not gate rule loading" ;;
        inert|missing) LF_RECOVERY="NFTBan loads no rules at boot (projection ${LF_PROJECTION}); console" ;;
        *) LF_RECOVERY="UNKNOWN (projection state not read); console" ;;
    esac

    # --- disable unit record -----------------------------------------------------------
    local ur="${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/disable-units.state" ra=""
    if [[ ! -e "$ur" ]]; then
        LF_UNITREC="no record (prior unit state unknown)"
    elif [[ ! -r "$ur" ]]; then
        LF_UNITREC=UNKNOWN
    else
        ra="$(grep -m1 -E '^# recorded_at=' "$ur" 2>/dev/null || true)"
        LF_UNITREC="unit record present (recorded_at ${ra#\# recorded_at=})"
        [[ -n "$ra" ]] || LF_UNITREC="unit record present (recorded_at UNKNOWN)"
    fi

    # --- named mismatches ---------------------------------------------------------------
    [[ "$LF_CC_STATUS" == rollback-failed ]] && LF_NOTES+=("DIVERGENCE: ROLLBACK FAILED: NFTBan rules removed, host NOT protected by NFTBan")
    [[ -n "$LF_CC_CONFLICTS" ]] && LF_NOTES+=("EXPECTED: the rollback left file(s) edited again after the apply untouched: ${LF_CC_CONFLICTS}")
    [[ "$LF_CC" == UNKNOWN* ]] && LF_NOTES+=("UNKNOWN: commit-confirm record not read")
    if [[ "$LF_BYPASS" == DEGRADED* ]]; then
        LF_NOTES+=("DIVERGENCE: emergency bypass DEGRADED: ${LF_BYPASS#DEGRADED (}")
        LF_NOTES[-1]="${LF_NOTES[-1]%)}"
        return 0
    fi
    if [[ "$LF_BYPASS" == ACTIVE* ]]; then
        LF_NOTES+=("EXPECTED: EMERGENCY BYPASS ACTIVE for this boot (kernel nftban=disabled); stored choice: ${LF_STORED}. The projection reads INERT because the shipped inert file is bind-mounted over it for this boot only")
        return 0
    fi
    [[ "$LF_BYPASS" == UNKNOWN ]] && LF_NOTES+=("UNKNOWN: emergency bypass state not read")
    [[ "$LF_BYPASS" == "not present; bypass unit "* ]] && LF_NOTES+=("DIVERGENCE: the bypass unit is ${LF_BYPASS_UNIT}: the emergency bypass would not act before the first load")
    case "$LF_STORED" in
        enabled)
            [[ "$LF_TABLES" == absent ]] && LF_NOTES+=("DIVERGENCE: stored enabled, NFTBan tables absent in the kernel")
            [[ "$LF_TABLES" == partial* ]] && LF_NOTES+=("DIVERGENCE: stored enabled, NFTBan tables ${LF_TABLES}")
            [[ "$LF_PROJECTION" == inert ]] && LF_NOTES+=("DIVERGENCE: stored enabled, projection inert (NFTBan rules will not load at reboot)")
            [[ "$LF_PROJECTION" == missing ]] && LF_NOTES+=("DIVERGENCE: stored enabled, projection missing (NFTBan rules will not load at reboot)")
            [[ "$LF_NFTSVC" != enabled && "$LF_NFTSVC" != UNKNOWN ]] && LF_NOTES+=("DIVERGENCE: stored enabled, nftables.service is ${LF_NFTSVC} (the projection is not loaded at boot)")
            [[ "$LF_INCLUDE" == absent ]] && LF_NOTES+=("DIVERGENCE: stored enabled, the NFTBan include is absent from the distro nftables config") ;;
        disabled)
            if [[ "$LF_TABLES" == present || "$LF_TABLES" == partial* ]]; then
                if [[ "$LF_PROJECTION" == inert || "$LF_PROJECTION" == missing ]]; then
                    LF_NOTES+=("EXPECTED: stored disabled, NFTBan rules still active (expected after plain disable; removed at next reboot)")
                else
                    LF_NOTES+=("DIVERGENCE: stored disabled, NFTBan rules active and projection ${LF_PROJECTION} (they would load again at reboot)")
                fi
            fi
            [[ "$LF_PROJECTION" == active && "$LF_TABLES" == absent ]] && LF_NOTES+=("DIVERGENCE: stored disabled, projection active (NFTBan rules would load at reboot)") ;;
        *) LF_NOTES+=("UNKNOWN: stored choice not read; lifecycle consistency cannot be evaluated") ;;
    esac
    [[ "$LF_TABLES" == UNKNOWN ]] && LF_NOTES+=("UNKNOWN: kernel tables not read")
    [[ "$LF_PROJECTION" == UNKNOWN ]] && LF_NOTES+=("UNKNOWN: boot projection state not read")
    return 0
}

# nftban_lifecycle_render: human block (call after nftban_lifecycle_collect)
nftban_lifecycle_render() {
    local n
    echo ""
    echo "  Protection lifecycle"
    printf "  %-20s %s\n" "Stored choice......." "$LF_STORED"
    printf "  %-20s %s\n" "Applied now........." "tables ${LF_TABLES} · daemon ${LF_DAEMON} · timers active ${LF_TIMERS}"
    printf "  %-20s %s\n" "On reboot..........." "nftables.service ${LF_NFTSVC} · include ${LF_INCLUDE} · projection ${LF_PROJECTION}"
    printf "  %-20s %s\n" "Recovery............" "$LF_RECOVERY"
    printf "  %-20s %s\n" "Emergency bypass...." "$LF_BYPASS"
    printf "  %-20s %s\n" "Commit-confirm......" "$LF_CC"
    printf "  %-20s %s\n" "Applied baseline...." "$LF_BASELINE"
    printf "  %-20s %s\n" "Disable record......" "$LF_UNITREC"
    for n in "${LF_NOTES[@]+"${LF_NOTES[@]}"}"; do printf '    %s\n' "$n"; done
}

# nftban_lifecycle_json: one JSON object (call after nftban_lifecycle_collect)
nftban_lifecycle_json() {
    local n notes=""
    esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
    for n in "${LF_NOTES[@]+"${LF_NOTES[@]}"}"; do notes+="${notes:+,}\"$(esc "$n")\""; done
    printf '{"stored":"%s","applied":{"tables":"%s","daemon":"%s","timers_active":"%s"},"on_reboot":{"nftables_service":"%s","include":"%s","projection":"%s"},"recovery":"%s","emergency_bypass":"%s","commit_confirm":"%s","applied_baseline":"%s","disable_record":"%s","notes":[%s]}' \
        "$(esc "$LF_STORED")" "$(esc "$LF_TABLES")" "$(esc "$LF_DAEMON")" "$(esc "$LF_TIMERS")" \
        "$(esc "$LF_NFTSVC")" "$(esc "$LF_INCLUDE")" "$(esc "$LF_PROJECTION")" "$(esc "$LF_RECOVERY")" \
        "$(esc "$LF_BYPASS")" "$(esc "$LF_CC")" "$(esc "$LF_BASELINE")" "$(esc "$LF_UNITREC")" "$notes"
}
