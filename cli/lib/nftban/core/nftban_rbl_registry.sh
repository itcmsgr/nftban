#!/usr/bin/env bash
# =============================================================================
# NFTBan RBL Provider Registry — SLICE 1: substrate + flat-list compatibility
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_rbl_registry"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Additive typed-provider registry substrate for RBL (scope OPEN_SCOPE_RBL_PROVIDER_REGISTRY_SCOPE.md, slice 1). Provides a typed record model, a CONSERVATIVE projection of the legacy flat rbls.conf zones into typed records, a deterministic validator (fails on duplicate id/zone, bad enum, unsafe shell content, malformed structure), and an effective-provider projection. SLICE-1 INVARIANT: rbls.conf remains authoritative — the registry NEVER changes provider membership, order, or count; it only supplies typed metadata. Registry-absent or registry-invalid ⇒ the effective set is byte-identical to nftban_rbl_load_providers (never empty). No runtime YAML (keyed INI blocks parsed line-by-line, never sourced/evaled). Functions only; no top-level side effects; daemon byte-identical; RBL observe-only."
# meta:input="Legacy rbls.conf (via nftban_rbl_load_providers) + optional registry.conf (INI blocks)"
# meta:output="TSV typed records + domain:url effective list on stdout"
# meta:depends="bash,sort"
# meta:inventory.files="/etc/nftban/conf.d/rbl/registry.conf"
# meta:inventory.binaries="bash,sort"
# meta:inventory.env_vars="NFTBAN_RBL_REGISTRY_FILE,NFTBAN_RBL_PROVIDERS_FILE,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/rbl/registry.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

# Strict mode + single-load guard, matching the sibling sourced core libs
# (core/nftban_hostaddr.sh). RBL callers already run under strict mode before
# this file is sourced, so this is behavior-consistent, not a new side effect.
set -Eeuo pipefail
[[ -n "${_NFTBAN_RBL_REGISTRY_LOADED:-}" ]] && return 0
_NFTBAN_RBL_REGISTRY_LOADED=1

# Optional registry artifact — ABSENT by default (slice 1 ships no data file, so
# the effective set is driven entirely by the authoritative rbls.conf).
: "${NFTBAN_RBL_REGISTRY_FILE:=${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/registry.conf}"

# Internal TSV record schema (11 tab-separated columns), in this fixed order:
#   id  zone  query_type  scope  family  access  weight  role  group  state  info_url
# Allowed enum vocabularies (validation only; NO values are assigned to real
# providers in slice 1 — curation is slice 3, externally verified).
_NFTBAN_RBL_REG_QT="IP_DNSBL DOMAIN_URIBL URI_REPUTATION"
_NFTBAN_RBL_REG_SCOPE="MAIL_REPUTATION TOR_EXIT POLICY EXPLOIT MALWARE"
_NFTBAN_RBL_REG_FAMILY="IPV4 IPV6 IPV4_IPV6"
_NFTBAN_RBL_REG_ACCESS="PUBLIC DQS CREDENTIALED RATE_LIMITED_PUBLIC"
_NFTBAN_RBL_REG_WEIGHT="HIGH MEDIUM LOW INFORMATIONAL"
_NFTBAN_RBL_REG_ROLE="PRIMARY COMPONENT CLASSIFICATION SECONDARY"
_NFTBAN_RBL_REG_STATE="enabled disabled conditional retired excluded"
_NFTBAN_RBL_REG_FIELDS="zone query_type scope family access weight role group state info_url"

# Membership word in a space-padded list?
_nftban_rbl_reg_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Reject values carrying shell-dangerous content. The registry is PARSED, never
# sourced/evaled, but this is defence-in-depth so a hostile artifact can never
# influence a later expansion. Blocks $ ` ; | < > \ ( ) newline and $( .
_nftban_rbl_reg_safe() {
    local v="$1"
    [[ "$v" == *'$('* ]] && return 1
    [[ "$v" =~ [\$\`\;\|\<\>\\\(\)] ]] && return 1
    [[ "$v" == *$'\n'* ]] && return 1
    return 0
}

# A strict DNS hostname (must be dotted) — same shape the loader enforces.
_nftban_rbl_reg_is_dnsname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$ ]]
}

# Trim leading/trailing whitespace.
_nftban_rbl_reg_trim() {
    local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"
}

# CONSERVATIVE legacy projection: a bare `zone:url` → a typed record with safe,
# non-committal defaults (query_type=IP_DNSBL, state=enabled, its OWN group so
# nothing is grouped/deduped, PRIMARY role). NO weighting, NO grouping across
# providers, NO reclassification — those are later slices.
nftban_rbl_registry_legacy_record() {
    local zone="$1" url="${2:-}" id
    id="${zone//[^a-z0-9_]/_}"     # lower-slug id; zones are already lowercase
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$zone" "IP_DNSBL" "MAIL_REPUTATION" "IPV4_IPV6" "PUBLIC" "" "PRIMARY" "$id" "enabled" "$url"
}

# Parse an INI-block registry file into TSV records. Structural/enum/safety
# errors print to stderr and return non-zero (deterministic failure). Never
# sources the file. Emits nothing on error.
nftban_rbl_registry_parse() {
    local file="${1:-$NFTBAN_RBL_REGISTRY_FILE}"
    [[ -f "$file" ]] || return 0    # absent = empty registry, not an error
    local line lineno=0 cur_id="" rc=0
    local f_zone="" f_qt="IP_DNSBL" f_scope="MAIL_REPUTATION" f_family="IPV4_IPV6"
    local f_access="PUBLIC" f_weight="" f_role="PRIMARY" f_group="" f_state="enabled" f_url=""
    local out=""
    _flush() {
        [[ -z "$cur_id" ]] && return 0
        if [[ -z "$f_zone" ]]; then
            printf 'nftban: rbl registry: [%s] missing zone (%s)\n' "$cur_id" "$file" >&2; rc=1; return 0
        fi
        [[ -z "$f_group" ]] && f_group="$cur_id"
        out+="${cur_id}	${f_zone}	${f_qt}	${f_scope}	${f_family}	${f_access}	${f_weight}	${f_role}	${f_group}	${f_state}	${f_url}"$'\n'
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        line="$(_nftban_rbl_reg_trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[([A-Za-z0-9_]+)\]$ ]]; then
            _flush
            cur_id="${BASH_REMATCH[1]}"
            f_zone=""; f_qt="IP_DNSBL"; f_scope="MAIL_REPUTATION"; f_family="IPV4_IPV6"
            f_access="PUBLIC"; f_weight=""; f_role="PRIMARY"; f_group=""; f_state="enabled"; f_url=""
            continue
        fi
        if [[ "$line" != *"="* ]]; then
            printf 'nftban: rbl registry: malformed line %d: %q (%s)\n' "$lineno" "$line" "$file" >&2; rc=1; continue
        fi
        local key val
        key="$(_nftban_rbl_reg_trim "${line%%=*}")"
        val="$(_nftban_rbl_reg_trim "${line#*=}")"
        if [[ -z "$cur_id" ]]; then
            printf 'nftban: rbl registry: key %q outside any [id] block (%s:%d)\n' "$key" "$file" "$lineno" >&2; rc=1; continue
        fi
        if ! _nftban_rbl_reg_in "$key" "$_NFTBAN_RBL_REG_FIELDS"; then
            printf 'nftban: rbl registry: unknown field %q in [%s] (%s:%d)\n' "$key" "$cur_id" "$file" "$lineno" >&2; rc=1; continue
        fi
        if ! _nftban_rbl_reg_safe "$val"; then
            printf 'nftban: rbl registry: unsafe value for %q in [%s] (%s:%d)\n' "$key" "$cur_id" "$file" "$lineno" >&2; rc=1; continue
        fi
        case "$key" in
            zone) f_zone="$val" ;; query_type) f_qt="$val" ;; scope) f_scope="$val" ;;
            family) f_family="$val" ;; access) f_access="$val" ;; weight) f_weight="$val" ;;
            role) f_role="$val" ;; group) f_group="$val" ;; state) f_state="$val" ;; info_url) f_url="$val" ;;
        esac
    done < "$file"
    _flush
    printf '%s' "$out"
    return $rc
}

# Validate a registry file deterministically. Non-zero on ANY of: parse error,
# bad id, duplicate id, duplicate zone, invalid enum, invalid zone name, unsafe
# content. Prints each violation to stderr.
nftban_rbl_registry_validate() {
    local file="${1:-$NFTBAN_RBL_REGISTRY_FILE}"
    [[ -f "$file" ]] || return 0
    local records rc=0
    records="$(nftban_rbl_registry_parse "$file")" || rc=1
    local seen_id=" " seen_zone=" "
    local id zone qt scope family access weight role group state url line
    # TAB is an IFS-whitespace char, so `IFS=$'\t' read` COLLAPSES empty columns
    # (e.g. an empty weight) and misaligns the record. Remap TAB → US (0x1f, not
    # IFS-whitespace) so empty fields are preserved.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=$'\x1f' read -r id zone qt scope family access weight role group state url <<< "${line//$'\t'/$'\x1f'}"
        [[ -z "$id" ]] && continue
        [[ "$id" =~ ^[a-z0-9_]+$ ]] || { printf 'nftban: rbl registry: invalid id %q (must be [a-z0-9_])\n' "$id" >&2; rc=1; }
        _nftban_rbl_reg_is_dnsname "$zone" || { printf 'nftban: rbl registry: invalid zone %q in [%s]\n' "$zone" "$id" >&2; rc=1; }
        case "$seen_id" in *" $id "*) printf 'nftban: rbl registry: duplicate id %q\n' "$id" >&2; rc=1 ;; *) seen_id+="$id " ;; esac
        case "$seen_zone" in *" $zone "*) printf 'nftban: rbl registry: duplicate zone %q\n' "$zone" >&2; rc=1 ;; *) seen_zone+="$zone " ;; esac
        _nftban_rbl_reg_in "$qt" "$_NFTBAN_RBL_REG_QT"       || { printf 'nftban: rbl registry: invalid query_type %q in [%s]\n' "$qt" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$scope" "$_NFTBAN_RBL_REG_SCOPE" || { printf 'nftban: rbl registry: invalid scope %q in [%s]\n' "$scope" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$family" "$_NFTBAN_RBL_REG_FAMILY" || { printf 'nftban: rbl registry: invalid family %q in [%s]\n' "$family" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$access" "$_NFTBAN_RBL_REG_ACCESS" || { printf 'nftban: rbl registry: invalid access %q in [%s]\n' "$access" "$id" >&2; rc=1; }
        [[ -z "$weight" ]] || _nftban_rbl_reg_in "$weight" "$_NFTBAN_RBL_REG_WEIGHT" || { printf 'nftban: rbl registry: invalid weight %q in [%s]\n' "$weight" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$role" "$_NFTBAN_RBL_REG_ROLE"   || { printf 'nftban: rbl registry: invalid role %q in [%s]\n' "$role" "$id" >&2; rc=1; }
        [[ -z "$group" || "$group" =~ ^[a-z0-9_]+$ ]]        || { printf 'nftban: rbl registry: invalid group %q in [%s] (must be [a-z0-9_])\n' "$group" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$state" "$_NFTBAN_RBL_REG_STATE" || { printf 'nftban: rbl registry: invalid state %q in [%s]\n' "$state" "$id" >&2; rc=1; }
    done <<< "$records"
    return $rc
}

# Typed records for the CURRENT effective provider set. Membership + order come
# from the authoritative legacy loader (rbls.conf); each zone is projected to a
# conservative legacy record. (Registry-supplied metadata overlay is a later
# slice; slice 1 proves the projection + never changes membership.)
nftban_rbl_registry_records() {
    local line domain url
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        domain="${line%%:*}"; url="${line#*:}"
        [[ "$url" == "$line" ]] && url=""
        nftban_rbl_registry_legacy_record "$domain" "$url"
    done < <(nftban_rbl_load_providers)
}

# Effective provider list (domain:url), the flat-list-compatibility bridge.
# SLICE-1 GUARANTEE: byte-identical to nftban_rbl_load_providers. rbls.conf is
# authoritative; the registry only supplies metadata and NEVER changes the set.
# If a registry artifact is present but invalid, we emit a warning and STILL
# return the authoritative legacy set — a malformed registry can never yield an
# empty (or altered) effective provider list.
nftban_rbl_registry_effective() {
    if [[ -f "$NFTBAN_RBL_REGISTRY_FILE" ]]; then
        if ! nftban_rbl_registry_validate "$NFTBAN_RBL_REGISTRY_FILE" >/dev/null 2>&1; then
            printf 'nftban: rbl registry: %s is invalid — ignoring it; using authoritative rbls.conf\n' \
                "$NFTBAN_RBL_REGISTRY_FILE" >&2
        fi
    fi
    # Membership is always the authoritative legacy set in slice 1.
    nftban_rbl_load_providers
}

export -f _nftban_rbl_reg_in _nftban_rbl_reg_safe _nftban_rbl_reg_is_dnsname _nftban_rbl_reg_trim 2>/dev/null || true
export -f nftban_rbl_registry_legacy_record nftban_rbl_registry_parse nftban_rbl_registry_validate 2>/dev/null || true
export -f nftban_rbl_registry_records nftban_rbl_registry_effective 2>/dev/null || true
