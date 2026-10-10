#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_forward" meta:type="lib" meta:version="1.235.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="v1.235 forwarding policy store (owner D1-D5, 2026-10-06; bans Q1/Q2 2026-10-08). The single source of truth for NFTBan's forwarding allows is /etc/nftban/forward.d/forward.conf, written only by `nftban firewall forward allow|remove|migrate`. Every render projects it into the fwd_* sets of the nftban forward chain (same transaction as the rules, and the boot projection). Records: egress|<ifname>|<comment>|<date>, uplink|<ifname>|<comment>|<date>, publish|<tcp|udp>|<host port>|<4|6>|<addr|prefix|any>|<comment>|<date>. A bad line is reported and skipped, never guessed. Discovery never writes here."
# meta:inventory.files="/etc/nftban/forward.d/forward.conf"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/forward.d/forward.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root to write the store"

# Guard: prevent double-loading. Sets no shell options (sourced into the CLI).
[[ -n "${_NFTBAN_FORWARD_LOADED:-}" ]] && return 0
_NFTBAN_FORWARD_LOADED=1

nftban_forward_store_path() { printf '%s' "${NFTBAN_CONFIG_DIR:-/etc/nftban}/forward.d/forward.conf"; }

_nftban_fwd_load_validation() {
    declare -F nftban_validate_ipv4 >/dev/null 2>&1 && return 0
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/validation.sh" 2>/dev/null || return 1
    declare -F nftban_validate_ipv4 >/dev/null 2>&1
}

_nftban_fwd_valid_ifname() { [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; }

# _nftban_fwd_valid_source <4|6> <addr|prefix|any>
_nftban_fwd_valid_source() {
    local fam="$1" src="$2" ip prefix
    [[ "$src" == "any" ]] && return 0
    _nftban_fwd_load_validation || return 1
    if [[ "$src" == */* ]]; then
        ip="${src%/*}"; prefix="${src##*/}"
        [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
        if [[ "$fam" == 4 ]]; then nftban_validate_ipv4 "$ip" && (( prefix <= 32 )); else nftban_validate_ipv6 "$ip" && (( prefix <= 128 )); fi
    else
        if [[ "$fam" == 4 ]]; then nftban_validate_ipv4 "$src"; else nftban_validate_ipv6 "$src"; fi
    fi
}

# nftban_forward_valid_record <line> : 0 valid, 1 invalid (reason on stdout)
nftban_forward_valid_record() {
    local line="$1" kind
    local -a f=()
    IFS='|' read -r -a f <<<"$line"
    kind="${f[0]:-}"
    case "$kind" in
        egress|uplink)
            [[ ${#f[@]} -ge 2 ]] || { echo "missing interface"; return 1; }
            _nftban_fwd_valid_ifname "${f[1]}" || { echo "invalid interface name '${f[1]}'"; return 1; } ;;
        publish)
            [[ ${#f[@]} -ge 5 ]] || { echo "publish needs proto|port|family|source"; return 1; }
            [[ "${f[1]}" == tcp || "${f[1]}" == udp ]] || { echo "protocol must be tcp or udp"; return 1; }
            [[ "${f[2]}" =~ ^[1-9][0-9]{0,4}$ ]] && (( f[2] <= 65535 )) || { echo "invalid port '${f[2]}'"; return 1; }
            [[ "${f[3]}" == 4 || "${f[3]}" == 6 ]] || { echo "family must be 4 or 6"; return 1; }
            _nftban_fwd_valid_source "${f[3]}" "${f[4]}" || { echo "invalid IPv${f[3]} source '${f[4]}'"; return 1; } ;;
        *) echo "unknown record type '${kind}'"; return 1 ;;
    esac
    return 0
}

# nftban_forward_records : valid records on stdout (comments/blank skipped);
# invalid lines reported on stderr and skipped. rc 2 = store present but unreadable.
nftban_forward_records() {
    local store n=0 line why
    store="$(nftban_forward_store_path)"
    [[ -e "$store" ]] || return 0
    [[ -r "$store" ]] || { echo "nftban: forward store unreadable: $store" >&2; return 2; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        if why=$(nftban_forward_valid_record "$line"); then
            printf '%s\n' "$line"
        else
            echo "nftban: $store:$n: invalid record skipped ($why): $line" >&2
        fi
    done < "$store"
    return 0
}

# _nftban_fwd_join <element...> : one `elements = { a, b }` line, or nothing when empty.
_nftban_fwd_join() {
    [[ $# -gt 0 ]] || return 0
    local out="" e
    for e in "$@"; do out="${out:+$out, }$e"; done
    printf '        elements = { %s }' "$out"
}

# nftban_forward_render_elements : sets FWD_EL_EGRESS FWD_EL_UPLINK FWD_EL_PUB_TCP4
# FWD_EL_PUB_UDP4 FWD_EL_PUB_TCP6 FWD_EL_PUB_UDP6 to an `elements = { ... }` line, or
# to empty when there is no record. rc 2 = the store could not be read (caller refuses).
# shellcheck disable=SC2034  # the FWD_EL_* assignments ARE the output (read by the caller's render)
nftban_forward_render_elements() {
    local recs rc=0 kind a b c d src line
    local -a eg=() up=() t4=() u4=() t6=() u6=() f=()
    recs=$(nftban_forward_records) || rc=$?
    [[ $rc -eq 2 ]] && return 2
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS='|' read -r -a f <<<"$line"
        kind="${f[0]}"
        case "$kind" in
            egress) eg+=("\"${f[1]}\"") ;;
            uplink) up+=("\"${f[1]}\"") ;;
            publish)
                a="${f[1]}"; b="${f[2]}"; c="${f[3]}"; d="${f[4]}"
                if [[ "$c" == 4 ]]; then src="$d"; [[ "$d" == any ]] && src="0.0.0.0/0"; [[ "$a" == tcp ]] && t4+=("$b . $src") || u4+=("$b . $src")
                else src="$d"; [[ "$d" == any ]] && src="::/0"; [[ "$a" == tcp ]] && t6+=("$b . $src") || u6+=("$b . $src"); fi ;;
        esac
    done <<<"$recs"
    FWD_EL_EGRESS="$(_nftban_fwd_join "${eg[@]}")"; FWD_EL_UPLINK="$(_nftban_fwd_join "${up[@]}")"
    FWD_EL_PUB_TCP4="$(_nftban_fwd_join "${t4[@]}")"; FWD_EL_PUB_UDP4="$(_nftban_fwd_join "${u4[@]}")"
    FWD_EL_PUB_TCP6="$(_nftban_fwd_join "${t6[@]}")"; FWD_EL_PUB_UDP6="$(_nftban_fwd_join "${u6[@]}")"
    return 0
}

# _nftban_fwd_write <content-file> : atomic replace of the store (root:nftban 0640).
_nftban_fwd_write() {
    local src="$1" store dir tmp
    store="$(nftban_forward_store_path)"; dir="$(dirname "$store")"
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "${store}.XXXXXX") || return 1
    cat "$src" > "$tmp" && chmod 0640 "$tmp" && { chgrp nftban "$tmp" 2>/dev/null || true; } && mv -f "$tmp" "$store" \
        || { rm -f "$tmp"; return 1; }
}

# nftban_forward_add <record-without-date> [comment] : appends one validated record.
# rc 0 added, 1 invalid, 3 already present (same key), 2 store unreadable/unwritable.
nftban_forward_add() {
    local rec="$1" comment="${2:-}" why key cur tmp
    why=$(nftban_forward_valid_record "$rec") || { echo "nftban: refused: $why" >&2; return 1; }
    comment="${comment//|/ }"; comment="${comment//$'\n'/ }"; comment="${comment:0:120}"
    key="$rec"
    cur=$(nftban_forward_records) || return 2
    if [[ $'\n'"$cur"$'\n' == *$'\n'"$key"[$'|\n']* ]]; then
        echo "nftban: already present: $key" >&2; return 3
    fi
    tmp=$(mktemp) || return 2
    { [[ -e "$(nftban_forward_store_path)" ]] && cat "$(nftban_forward_store_path)"; printf '%s|%s|%s\n' "$rec" "$comment" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$tmp"
    _nftban_fwd_write "$tmp" || { rm -f "$tmp"; return 2; }
    rm -f "$tmp"
}

# nftban_forward_remove <record-key> : removes every record whose key matches.
# rc 0 removed, 4 not present, 2 store unreadable/unwritable.
nftban_forward_remove() {
    local key="$1" store tmp
    store="$(nftban_forward_store_path)"
    [[ -e "$store" ]] || { echo "nftban: not present: $key" >&2; return 4; }
    [[ -r "$store" ]] || return 2
    tmp=$(mktemp) || return 2
    awk -F'|' -v k="$key" '{n=split(k,a,"|"); m=""; for(i=1;i<=n;i++) m=m (i>1?"|":"") $i; if (m==k) {gone++; next} print} END{exit gone?0:4}' "$store" > "$tmp"
    local rc=$?
    if [[ $rc -ne 0 ]]; then rm -f "$tmp"; echo "nftban: not present: $key" >&2; return 4; fi
    _nftban_fwd_write "$tmp" || { rm -f "$tmp"; return 2; }
    rm -f "$tmp"
}

# =============================================================================
# CLI: nftban firewall forward status|list|allow|remove   (owner D3/D4, v1.235)
# Writing commands change ONLY the store; applying is `nftban firewall rebuild
# [--confirm]` (no second apply mechanism). Discovery (status) never writes.
# =============================================================================

# D3: egress only for RECOGNISED and TESTED bridge shapes. v1.235 = Docker CE bridge
# driver (docker0, br-<12 hex>). No override: an unrecognised bridge is refused.
nftban_forward_recognised_bridge() { [[ "$1" == docker0 || "$1" =~ ^br-[0-9a-f]{12}$ ]]; }

nftban_forward_usage() {
    cat <<'USAGE'
Usage: nftban firewall forward <command>

  status                         read-only: policy, stored allows, managed and UNMANAGED
                                 rules in the nftban forward chain, bridges, uplinks,
                                 published ports and NFTBan's verdict for each
  list                           print the stored allows (/etc/nftban/forward.d/forward.conf)
  allow egress <bridge>  [--comment TEXT]   let a recognised Docker bridge reach the uplinks
  allow uplink <iface>   [--comment TEXT]   an interface container egress may leave by
  allow publish <port>/<tcp|udp> --from <addr|prefix|any> --family 4|6 [--comment TEXT]
                                 open one published host port to one source (per family)
  remove egress|uplink|publish ...          same keys as allow
  migrate [--confirm <plan id>]  map UNMANAGED forward rules to stored allows (shows every
                                 behaviour difference; writes only with the plan's id)

Writing commands only change the store. Apply with:
  nftban firewall rebuild --confirm      (pending change, rolled back unless confirmed)
Policy (v1.235): forwarded traffic is dropped unless allowed here; bans apply to forwarded
traffic in both directions; a whitelisted source is exempt from the ban, never accepted.
USAGE
}

nftban_forward_list() {
    local recs rc=0
    recs=$(nftban_forward_records) || rc=$?
    [[ $rc -eq 2 ]] && return 2
    echo "Stored forwarding allows: $(nftban_forward_store_path)"
    if [[ -z "$recs" ]]; then echo "  (none: nothing is forwarded)"; return 0; fi
    printf '%s\n' "$recs" | awk -F'|' '
        $1=="egress"  {printf "  egress   %-16s %s\n", $2, $3}
        $1=="uplink"  {printf "  uplink   %-16s %s\n", $2, $3}
        $1=="publish" {printf "  publish  %s/%s from %s (IPv%s)  %s\n", $3, $2, $5, $4, $6}'
}

# _nftban_fwd_parse_key <allow|remove> <args...> : prints the record key, rc 1 on bad args.
# Sets _FWD_COMMENT.
_nftban_fwd_parse_key() {
    local verb="$1" kind="${2:-}"; shift 2 2>/dev/null || true
    local from="" fam="" pp="" iface=""
    _FWD_COMMENT=""
    case "$kind" in
        egress|uplink) iface="${1:-}"; shift || true ;;
        publish) pp="${1:-}"; shift || true ;;
        *) echo "nftban: forward $verb: expected egress|uplink|publish" >&2; return 1 ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="${2:-}"; shift 2 ;;
            --family) fam="${2:-}"; shift 2 ;;
            --comment) _FWD_COMMENT="${2:-}"; shift 2 ;;
            *) echo "nftban: forward $verb: unknown argument '$1'" >&2; return 1 ;;
        esac
    done
    case "$kind" in
        egress|uplink) [[ -n "$iface" ]] || { echo "nftban: forward $verb $kind: interface required" >&2; return 1; }
                       printf '%s|%s' "$kind" "$iface" ;;
        publish) [[ "$pp" =~ ^([0-9]+)/(tcp|udp)$ ]] || { echo "nftban: forward $verb publish: expected <port>/<tcp|udp>" >&2; return 1; }
                 [[ -n "$from" && -n "$fam" ]] || { echo "nftban: forward $verb publish: --from and --family are required" >&2; return 1; }
                 printf 'publish|%s|%s|%s|%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "$fam" "$from" ;;
    esac
}

nftban_forward_allow_remove() {
    local verb="$1"; shift
    local key rc kind
    [[ $(id -u) -eq 0 ]] || { echo "nftban: forward $verb: root required (writes $(nftban_forward_store_path))" >&2; return 1; }
    key=$(_nftban_fwd_parse_key "$verb" "$@") || return 1
    # The parser runs in a command substitution, so its _FWD_COMMENT never reaches this shell
    # (v1.235 Docker lab: every `forward allow` without --comment died "_FWD_COMMENT: unbound
    # variable", and a given --comment was dropped). Read it here.
    local _FWD_COMMENT="" _fa _fprev=""
    for _fa in "$@"; do [[ "$_fprev" == --comment ]] && _FWD_COMMENT="$_fa"; _fprev="$_fa"; done
    kind="${key%%|*}"
    if [[ "$verb" == allow && "$kind" == egress ]] && ! nftban_forward_recognised_bridge "${key#egress|}"; then
        echo "nftban: refused: '${key#egress|}' is not a recognised and tested bridge (v1.235 supports the Docker CE bridge driver: docker0, br-<12 hex>)" >&2
        return 1
    fi
    if [[ "$verb" == allow ]]; then
        nftban_forward_add "$key" "$_FWD_COMMENT"; rc=$?
        [[ $rc -eq 0 ]] && echo "Recorded: $key"
    else
        nftban_forward_remove "$key"; rc=$?
        [[ $rc -eq 0 ]] && echo "Removed: $key"
    fi
    [[ $rc -eq 0 ]] && echo "Not applied yet. Apply with: nftban firewall rebuild --confirm"
    return $rc
}

nftban_forward_status() {
    local fam out rc tag untag recs
    echo "NFTBan forwarding (v1.235): forwarded traffic is dropped unless allowed below;"
    echo "  bans apply to forwarded traffic in both directions; whitelisted sources are exempt from bans."
    echo ""
    nftban_forward_list || echo "  forward store: UNKNOWN (unreadable)"
    echo ""
    echo "Kernel (nftban forward chain):"
    for fam in ip ip6; do
        if ! out=$(nft -a list chain "$fam" nftban forward 2>&1); then
            case "$out" in *"No such file or directory"*) echo "  $fam: no nftban forward chain";; *) echo "  $fam: UNKNOWN (read failed: ${out%%$'\n'*})";; esac
            continue
        fi
        rc=""; [[ "$out" =~ policy\ ([a-z]+) ]] && rc="${BASH_REMATCH[1]}"
        tag=$(printf '%s\n' "$out" | grep -cF 'comment "nftban:fwd:' || true)
        untag=$(printf '%s\n' "$out" | grep -E '# handle [0-9]+$' | grep -vE '^[[:space:]]*(table|chain)[[:space:]]' | grep -vF 'comment "nftban:fwd:' || true)
        echo "  $fam: policy ${rc:-UNKNOWN}, ${tag} NFTBan rule(s)"
        if [[ -n "$untag" ]]; then
            echo "  $fam: UNMANAGED rule(s) (not created by NFTBan; rebuild/reset/reload/restore/takeover, update and package upgrade STOP until they are migrated: nftban firewall forward migrate):"
            printf '%s\n' "$untag" | sed 's/^[[:space:]]*/      /'
        fi
    done
    echo ""
    echo "Forwarding sysctls (report only): ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo UNKNOWN), ipv6 forwarding=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo UNKNOWN)"
    local _rs
    if _rs=$(nft list ruleset 2>/dev/null); then
        out=$(printf '%s\n' "$_rs" | awk '/^table /{t=$2" "$3} /hook forward/ && t !~ / nftban$/ {print "  " t}' | sort -u)
        echo "Foreign forward-hook chains: ${out:+$'\n'$out}${out:-none}"
    else
        echo "Foreign forward-hook chains: UNKNOWN (ruleset read failed)"
    fi
    echo ""
    recs=$(nftban_forward_records 2>/dev/null || true)
    echo "Bridges (discovery informs; nothing is written):"
    out=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' || true)
    if [[ -z "$out" ]]; then echo "  none"; else
        while IFS= read -r b; do
            [[ -n "$b" ]] || continue
            if [[ $'\n'"$recs"$'\n' == *$'\n'"egress|${b}"[$'|\n']* ]]; then echo "  $b: egress ALLOWED (stored)"
            elif nftban_forward_recognised_bridge "$b"; then echo "  $b: recognised (Docker bridge); not allowed. To allow: nftban firewall forward allow egress $b"
            else echo "  $b: not a recognised and tested bridge (not supported in v1.235)"; fi
        done <<<"$out"
    fi
    echo "Uplink candidates (default routes):"
    out=$( { ip -o route show default 2>/dev/null; ip -6 -o route show default 2>/dev/null; } | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | sort -u || true)
    if [[ -z "$out" ]]; then echo "  none"; else
        while IFS= read -r u; do
            [[ -n "$u" ]] || continue
            if [[ $'\n'"$recs"$'\n' == *$'\n'"uplink|${u}"[$'|\n']* ]]; then echo "  $u: uplink ALLOWED (stored)"
            else echo "  $u: not allowed. To allow: nftban firewall forward allow uplink $u"; fi
        done <<<"$out"
    fi
    echo ""
    echo "Published ports (DNAT in foreign tables) and NFTBan's stored verdict:"
    if command -v jq >/dev/null 2>&1 && out=$(nft -j list ruleset 2>/dev/null); then
        out=$(printf '%s' "$out" | jq -r '
            .nftables[] | select(.rule) | .rule | select(.table != "nftban")
            | select([.expr[]? | has("dnat")] | any)
            | [ .family,
                ([.expr[]? | .match? | select(.left.payload.field? == "dport") | .left.payload.protocol][0] // "?"),
                ([.expr[]? | .match? | select(.left.payload.field? == "dport") | .right][0] // "?") ]
            | @tsv' 2>/dev/null | sort -u || true)
        if [[ -z "$out" ]]; then echo "  none"; else
            while IFS=$'\t' read -r f p port; do
                [[ "$port" =~ ^[0-9]+$ ]] || { echo "  $f $p/$port: UNKNOWN (port not a single number)"; continue; }
                local srcs; srcs=$(printf '%s\n' "$recs" | awk -F'|' -v p="$p" -v n="$port" '$1=="publish" && $2==p && $3==n {print $5" (IPv"$4")"}' | paste -sd, - || true)
                if [[ -n "$srcs" ]]; then echo "  $port/$p ($f DNAT): allowed for $srcs (stored; applied at the last rebuild)"
                else echo "  $port/$p ($f DNAT): not allowed: blocked by the NFTBan forward policy"; fi
            done <<<"$out"
        fi
    else
        echo "  UNKNOWN (nft -j / jq not available)"
    fi
    return 0
}

# nftban firewall forward migrate [--confirm <plan id>] : the SAME mapper and plan id as the
# package upgrade (cli/lib/nftban/lib/nftban_immutable_owned.sh). Without --confirm it only
# prints the plan. It never deletes a rule; applying is `nftban firewall rebuild --confirm`.
nftban_forward_migrate() {
    local want="" rules plan prc=0 id
    case "${1:-}" in
        "") ;;
        --confirm) want="${2:-}"; [[ -n "$want" ]] || { echo "nftban: forward migrate --confirm <plan id>" >&2; return 1; } ;;
        *) echo "nftban: forward migrate: unknown argument '$1'" >&2; return 1 ;;
    esac
    # shellcheck source=/dev/null
    declare -F nftban_forward_migration_plan >/dev/null 2>&1 \
        || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_immutable_owned.sh" || return 1
    rules=$(nftban_forward_unmanaged_rules) || { echo "nftban: forward chain UNKNOWN: nothing done" >&2; return 1; }
    if [[ -z "$rules" ]]; then echo "No unmanaged rule in the nftban forward chain: nothing to migrate."; return 0; fi
    plan=$(nftban_forward_migration_plan "$rules") || prc=$?
    id=$(nftban_forward_plan_id "$plan")
    echo "Migration plan $id (old rule -> stored record; every DIFF changes behaviour):"
    printf '%s\n' "$plan" | sed 's/^/    /'
    if [[ $prc -ne 0 ]]; then echo "At least one rule is UNMAPPED: it cannot be migrated; nothing written."; return 1; fi
    if [[ -z "$want" ]]; then
        echo "To record EXACTLY this plan: nftban firewall forward migrate --confirm $id"
        return 0
    fi
    [[ $(id -u) -eq 0 ]] || { echo "nftban: forward migrate --confirm: root required" >&2; return 1; }
    [[ "$want" == "$id" ]] || { echo "nftban: plan id mismatch (approved $want, current $id): review the plan; nothing written" >&2; return 1; }
    nftban_forward_apply_plan "$plan" || return 1
    echo "Recorded in $(nftban_forward_store_path). Apply with: nftban firewall rebuild --confirm"
}

nftban_forward_cli() {
    local sub="${1:-status}"; [[ $# -gt 0 ]] && shift
    case "$sub" in
        status) nftban_forward_status ;;
        list) nftban_forward_list ;;
        allow|remove) nftban_forward_allow_remove "$sub" "$@" ;;
        migrate) nftban_forward_migrate "$@" ;;
        help|-h|--help) nftban_forward_usage ;;
        *) echo "nftban: unknown forward command '$sub'" >&2; nftban_forward_usage >&2; return 1 ;;
    esac
}
