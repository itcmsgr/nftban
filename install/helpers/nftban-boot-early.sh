#!/usr/bin/env bash
# =============================================================================
# NFTBan - early boot guard (v1.235 row 486: U1 + R-DEC)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban-boot-early"
# meta:type="helper"
# meta:version="1.235.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="Runs in early boot, BEFORE the distro nftables.service loads the NFTBan boot projection (and once after it, as a declared backstop). Modes: bypass (kernel parameter nftban=disabled: make the projection inert for THIS boot only: bind mount, else rename-swap, else create), bypass-guard (after nftables.service: if NFTBan tables were loaded despite the bypass, delete ip/ip6 nftban only and record it as a DIVERGENCE), normal (no parameter: undo a previous bypass rename-swap; when the stored master switch is off, make sure the projection is inert, so a disabled NFTBan never loads at boot). Never touches nftables.service, the distro config, foreign tables or NFTBAN_ENABLED. Per-boot state goes to /run (tmpfs): /var may not be mounted yet, and nothing here may order nftables.service after /var."
# meta:inventory.files="/etc/nftban/generated/nftban-boot.nft,/usr/lib/nftban/data/nftban-boot-inert.nft,/run/nftban/boot-bypass.state"
# meta:inventory.binaries="mount,nft,install,mv,restorecon"
# meta:inventory.privileges="root (early boot, systemd)"
# =============================================================================
set -u

PROJ="${NFTBAN_BOOT_PROJECTION:-/etc/nftban/generated/nftban-boot.nft}"
INERT="${NFTBAN_BOOT_INERT:-/usr/lib/nftban/data/nftban-boot-inert.nft}"
SAVED="${PROJ}.bypassed"
STATE_DIR="${NFTBAN_BOOT_STATE_DIR:-/run/nftban}"
STATE="${STATE_DIR}/boot-bypass.state"
MARKER='# NFTBAN-PROJECTION-STATE: inert'
SERVICES_CONF="${NFTBAN_SERVICES_CONF:-/etc/nftban/conf.d/services.conf}"   # same file + .local as lib/service_control.sh

log() { echo "nftban-boot-early: $*"; }

record() {  # outcome detail
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    {
        echo "outcome=$1"
        echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "monotonic_us=$(awk '{printf "%d", $1*1000000}' /proc/uptime 2>/dev/null)"
        echo "detail=$2"
    } > "${STATE}.tmp" 2>/dev/null && mv -f "${STATE}.tmp" "$STATE" 2>/dev/null
    log "$1: $2"
}

relabel() { command -v restorecon >/dev/null 2>&1 && restorecon -F "$1" 2>/dev/null; return 0; }

inert_body() {
    if [[ -s "$INERT" ]]; then cat "$INERT"; return 0; fi
    printf '%s\n' '#!/usr/sbin/nft -f' "$MARKER" \
        '# NFTBan is disabled (or bypassed for this boot): no NFTBan table is defined.'
}

# Atomic in-place write of the inert body (same directory, then rename).
write_inert_at() {  # path
    local tmp="${1}.inert.$$"
    inert_body > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
    relabel "$1"
}

# v1.235 K2: the ONE NFTBAN_ENABLED contract, byte-identical to lib/service_control.sh (this
# helper runs before anything else and sources nothing; a census test keeps the copies equal).
_nftban_switch_word() {  # <declared value> -> on | off | invalid  (the ONE NFTBAN_ENABLED contract, owner K2)
    local v="$1" q
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
        \"*|\'*) q="${v:0:1}"; v="${v:1}"
                 [[ "$v" == *"$q"* ]] || { echo invalid; return 0; }
                 v="${v%%"$q"*}" ;;
        *) if [[ "$v" =~ ^([^[:space:]]*)[[:space:]]+#.*$ ]]; then v="${BASH_REMATCH[1]}"; fi ;;
    esac
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "${v,,}" in true|yes|1|on) echo on ;; false|no|0|off) echo off ;; *) echo invalid ;; esac
}

stored_switch_state() {  # on | off | invalid | unknown — services.conf(.local), last wins; absent = on
    local st="on" f line
    for f in "$SERVICES_CONF" "${SERVICES_CONF}.local"; do
        [[ -e "$f" || -L "$f" ]] || continue
        # K2-c: present but unreadable = UNKNOWN (wins; same rule as lib/service_control.sh).
        if [[ ! -f "$f" || ! -r "$f" ]]; then printf 'unknown\n'; return 0; fi
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            case "$line" in NFTBAN_ENABLED=*) st="$(_nftban_switch_word "${line#NFTBAN_ENABLED=}")" ;; esac
        done < "$f"
    done
    printf '%s\n' "$st"
}

mode_bypass() {
    # 1. Primary: bind the shipped inert file over the projection (this boot only).
    if [[ -s "$INERT" && -e "$PROJ" ]] && mount --bind "$INERT" "$PROJ" 2>/dev/null; then
        record primary "bind-mounted $INERT over $PROJ"
        return 0
    fi
    # 2. Projection missing: create the inert file so the distro include still loads foreign rules.
    if [[ ! -e "$PROJ" ]]; then
        mkdir -p "$(dirname "$PROJ")" 2>/dev/null || true
        if write_inert_at "$PROJ"; then record created-inert "projection was missing; inert file created"; return 0; fi
        record failed "projection missing and the inert file could not be created"; return 1
    fi
    # 3. Bind failed or shipped file missing: rename-swap (reversed at the next normal boot).
    #    Already inert (e.g. NFTBan disabled): nothing to swap, the guarantee holds.
    if grep -qxF -- "$MARKER" "$PROJ" 2>/dev/null; then
        record fallback-rename "projection already inert; nothing to swap"
        return 0
    fi
    #    The CURRENT real projection is always the one saved (a stale .bypassed is replaced).
    if mv -f "$PROJ" "$SAVED" 2>/dev/null; then
        if write_inert_at "$PROJ"; then
            record fallback-rename "real projection moved to $SAVED; inert in place until the next normal boot"
            return 0
        fi
        mv -f "$SAVED" "$PROJ" 2>/dev/null || true
    fi
    record failed "could not make the projection inert (bind, create and rename all failed)"
    return 1
}

mode_bypass_guard() {
    command -v nft >/dev/null 2>&1 || { record backstop-unknown "nft not available; NFTBan tables NOT checked"; return 0; }
    local tables found=""
    if ! tables=$(nft list tables 2>&1); then
        record backstop-unknown "nft list tables failed: $tables"; return 0
    fi
    grep -qx 'table ip nftban' <<<"$tables" && found="ip"
    grep -qx 'table ip6 nftban' <<<"$tables" && found="${found:+$found }ip6"
    [[ -n "$found" ]] || return 0      # guarantee held; primary record stands
    local fam failed=""
    for fam in $found; do nft delete table "$fam" nftban 2>/dev/null || failed="${failed:+$failed }$fam"; done
    if [[ -z "$failed" ]]; then
        record backstop-removed "NFTBan tables ($found) WERE loaded during this bypass boot and were removed"
    else
        record backstop-failed "NFTBan tables ($found) loaded during this bypass boot; delete FAILED for: $failed"
    fi
    return 0
}

mode_normal() {
    # Undo a previous bypass rename-swap.
    if [[ -e "$SAVED" ]]; then
        if mv -f "$SAVED" "$PROJ"; then relabel "$PROJ"; log "restored the projection saved by a previous bypass boot"
        else log "WARNING: could not restore $SAVED"; fi
    fi
    # U1: a disabled NFTBan never loads at boot, even if the inert publish failed at disable time.
    # K2: an INVALID value changes nothing here (no inert rewrite): the last published projection loads.
    local _sw
    _sw="$(stored_switch_state)"
    if [[ "$_sw" == invalid ]]; then
        log "WARNING: NFTBAN_ENABLED is INVALID: boot projection left as last published (not made inert, not changed)"
    elif [[ "$_sw" == unknown ]]; then
        log "WARNING: NFTBAN_ENABLED could not be read (services.conf present but unreadable): boot projection left as last published (not made inert, not changed)"
    fi
    if [[ "$_sw" == off ]] && [[ -e "$PROJ" ]] && ! grep -qxF -- "$MARKER" "$PROJ" 2>/dev/null; then
        if write_inert_at "$PROJ"; then log "NFTBan is disabled (stored choice): projection made inert before nftables.service"
        else log "WARNING: NFTBan is disabled but the projection could not be made inert"; fi
    fi
    return 0
}

case "${1:-}" in
    bypass)        mode_bypass ;;
    bypass-guard)  mode_bypass_guard ;;
    normal)        mode_normal ;;
    *) echo "usage: nftban-boot-early {bypass|bypass-guard|normal}" >&2; exit 2 ;;
esac
