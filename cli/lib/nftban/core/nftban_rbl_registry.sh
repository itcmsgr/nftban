#!/usr/bin/env bash
# =============================================================================
# NFTBan RBL Provider Registry — substrate + typed metadata (slices 1/2/3A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_rbl_registry"
# meta:type="core"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Typed-provider registry for RBL (scope OPEN_SCOPE_RBL_PROVIDER_REGISTRY_SCOPE.md). Slice 1: additive substrate + flat-list compat. Slice 2: read-only providers CLI helpers. Slice 3A: truthful provider METADATA overlay — a 16-column typed record per configured zone (id/zone/query_type/scope/family/access/weight/role/group/state/operational_status/replacement/audit_date/confidence/license/info_url), sourced from an INI registry data file and validated deterministically. SLICE-3A INVARIANT: metadata ONLY — the effective queried set + order come from the authoritative legacy loader (rbls.conf); the registry NEVER changes membership, order, count, or which zone is queried. Registry-absent or registry-invalid yields the conservative legacy projection (byte-identical to slice-1 behavior). No runtime YAML (INI parsed line-by-line, never sourced/evaled). Functions only; no top-level side effects; daemon byte-identical; RBL observe-only."
# meta:input="Legacy rbls.conf (via nftban_rbl_load_providers) + optional registry.conf (INI blocks)"
# meta:output="TSV typed records + domain:url effective list on stdout"
# meta:depends="bash,sort,awk"
# meta:inventory.files="/etc/nftban/conf.d/rbl/registry.conf"
# meta:inventory.binaries="bash,sort,awk,dig"
# meta:inventory.env_vars="NFTBAN_RBL_REGISTRY_FILE,NFTBAN_RBL_PROVIDERS_FILE,NFTBAN_CONFIG_DIR,NFTBAN_RBL_TIMEOUT"
# meta:inventory.config_files="/etc/nftban/conf.d/rbl/registry.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="RBL DNS lookups (providers test only; read-only diagnostic)"
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
[[ -n "${_NFTBAN_RBL_REGISTRY_LOADED:-}" ]] && return 0
_NFTBAN_RBL_REGISTRY_LOADED=1

# Registry metadata artifact (slice 3A ships one). Absent yields the conservative
# legacy projection. Present yields typed metadata OVERLAY only — never membership.
: "${NFTBAN_RBL_REGISTRY_FILE:=${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/registry.conf}"

# Internal TSV record schema (16 tab-separated columns), fixed order:
#  id zone query_type scope family access weight role group state
#  operational_status replacement audit_date confidence license info_url
_NFTBAN_RBL_REG_QT="IP_DNSBL DOMAIN_URIBL URI_REPUTATION"
_NFTBAN_RBL_REG_SCOPE="MAIL_REPUTATION TOR_EXIT POLICY EXPLOIT MALWARE NETWORK_ALLOCATION ASN_REPUTATION"
_NFTBAN_RBL_REG_FAMILY="IPV4 IPV6 IPV4_IPV6"
_NFTBAN_RBL_REG_ACCESS="PUBLIC DQS CREDENTIALED RATE_LIMITED_PUBLIC REGISTERED_RESOLVER"
_NFTBAN_RBL_REG_WEIGHT="HIGH MEDIUM LOW INFORMATIONAL"
_NFTBAN_RBL_REG_ROLE="PRIMARY COMPONENT CLASSIFICATION SECONDARY AGGREGATE"
_NFTBAN_RBL_REG_STATE="enabled disabled conditional retired excluded"
_NFTBAN_RBL_REG_FIELDS="zone query_type scope family access weight role group state operational_status replacement audit_date confidence license info_url"

_nftban_rbl_reg_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Reject shell-dangerous content (defence-in-depth; the registry is PARSED, never
# sourced/evaled). Blocks $ ` ; | < > \ ( ) newline and $( .
_nftban_rbl_reg_safe() {
    local v="$1"
    [[ "$v" == *'$('* ]] && return 1
    [[ "$v" =~ [\$\`\;\|\<\>\\\(\)] ]] && return 1
    [[ "$v" == *$'\n'* ]] && return 1
    return 0
}
_nftban_rbl_reg_is_dnsname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$ ]]
}
_nftban_rbl_reg_trim() {
    local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"
}

# CONSERVATIVE legacy projection: a bare `zone:url` -> a typed record with safe,
# non-committal defaults. Used when no registry record matches the zone. The 5
# slice-3A metadata columns default to UNVERIFIED/empty — never inferred.
nftban_rbl_registry_legacy_record() {
    local zone="$1" url="${2:-}" id
    id="${zone//[^a-z0-9_]/_}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$zone" "IP_DNSBL" "MAIL_REPUTATION" "IPV4_IPV6" "PUBLIC" "" "PRIMARY" "$id" "enabled" \
        "UNVERIFIED" "" "" "UNVERIFIED" "UNVERIFIED" "$url"
}

# Parse an INI-block registry file into 16-col TSV. Structural/safety errors ->
# stderr + non-zero. Never sources the file.
nftban_rbl_registry_parse() {
    local file="${1:-$NFTBAN_RBL_REGISTRY_FILE}"
    [[ -f "$file" ]] || return 0
    local line lineno=0 cur_id="" rc=0 out=""
    local f_zone f_qt f_scope f_family f_access f_weight f_role f_group f_state f_op f_repl f_audit f_conf f_lic f_url
    _reset(){ f_zone=""; f_qt="IP_DNSBL"; f_scope="MAIL_REPUTATION"; f_family="IPV4_IPV6"; f_access="PUBLIC"
              f_weight=""; f_role="PRIMARY"; f_group=""; f_state="enabled"; f_op=""; f_repl=""; f_audit=""
              f_conf=""; f_lic=""; f_url=""; }
    _reset
    _flush() {
        [[ -z "$cur_id" ]] && return 0
        if [[ -z "$f_zone" ]]; then
            printf 'nftban: rbl registry: [%s] missing zone (%s)\n' "$cur_id" "$file" >&2; rc=1; return 0
        fi
        [[ -z "$f_group" ]] && f_group="$cur_id"
        out+="${cur_id}	${f_zone}	${f_qt}	${f_scope}	${f_family}	${f_access}	${f_weight}	${f_role}	${f_group}	${f_state}	${f_op}	${f_repl}	${f_audit}	${f_conf}	${f_lic}	${f_url}"$'\n'
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        line="$(_nftban_rbl_reg_trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[([A-Za-z0-9_]+)\]$ ]]; then
            _flush; cur_id="${BASH_REMATCH[1]}"; _reset; continue
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
            zone) f_zone="$val";; query_type) f_qt="$val";; scope) f_scope="$val";; family) f_family="$val";;
            access) f_access="$val";; weight) f_weight="$val";; role) f_role="$val";; group) f_group="$val";;
            state) f_state="$val";; operational_status) f_op="$val";; replacement) f_repl="$val";;
            audit_date) f_audit="$val";; confidence) f_conf="$val";; license) f_lic="$val";; info_url) f_url="$val";;
        esac
    done < "$file"
    _flush
    printf '%s' "$out"
    return $rc
}

# Validate a registry file deterministically. Non-zero on ANY of: parse error;
# bad/duplicate id or zone; invalid enum; invalid zone name; unsafe content;
# missing/malformed audit_date/confidence/operational_status; replacement not
# resolving to a declared record or an EXTERNAL: candidate; a cyclic internal
# replacement chain. Prints each violation to stderr.
nftban_rbl_registry_validate() {
    local file="${1:-$NFTBAN_RBL_REGISTRY_FILE}"
    [[ -f "$file" ]] || return 0
    local records rc=0
    records="$(nftban_rbl_registry_parse "$file")" || rc=1
    local seen_id=" " seen_zone=" " decl_zone=" " decl_id=" " repl_edges=""
    local id zone qt scope family access weight role group state op repl audit conf lic url line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=$'\x1f' read -r id zone qt scope family access weight role group state op repl audit conf lic url \
            <<< "${line//$'\t'/$'\x1f'}"
        [[ -z "$id" ]] && continue
        [[ "$id" =~ ^[a-z0-9_]+$ ]] || { printf 'nftban: rbl registry: invalid id %q\n' "$id" >&2; rc=1; }
        _nftban_rbl_reg_is_dnsname "$zone" || { printf 'nftban: rbl registry: invalid zone %q in [%s]\n' "$zone" "$id" >&2; rc=1; }
        case "$seen_id" in *" $id "*) printf 'nftban: rbl registry: duplicate id %q\n' "$id" >&2; rc=1 ;; *) seen_id+="$id " ;; esac
        case "$seen_zone" in *" $zone "*) printf 'nftban: rbl registry: duplicate zone %q\n' "$zone" >&2; rc=1 ;; *) seen_zone+="$zone " ;; esac
        decl_zone+="$zone "; decl_id+="$id "
        _nftban_rbl_reg_in "$qt" "$_NFTBAN_RBL_REG_QT"          || { printf 'nftban: rbl registry: invalid query_type %q in [%s]\n' "$qt" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$scope" "$_NFTBAN_RBL_REG_SCOPE"    || { printf 'nftban: rbl registry: invalid scope %q in [%s]\n' "$scope" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$family" "$_NFTBAN_RBL_REG_FAMILY"  || { printf 'nftban: rbl registry: invalid family %q in [%s]\n' "$family" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$access" "$_NFTBAN_RBL_REG_ACCESS"  || { printf 'nftban: rbl registry: invalid access %q in [%s]\n' "$access" "$id" >&2; rc=1; }
        [[ -z "$weight" ]] || _nftban_rbl_reg_in "$weight" "$_NFTBAN_RBL_REG_WEIGHT" || { printf 'nftban: rbl registry: invalid weight %q in [%s]\n' "$weight" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$role" "$_NFTBAN_RBL_REG_ROLE"      || { printf 'nftban: rbl registry: invalid role %q in [%s]\n' "$role" "$id" >&2; rc=1; }
        [[ -z "$group" || "$group" =~ ^[a-z0-9_]+$ ]]           || { printf 'nftban: rbl registry: invalid group %q in [%s]\n' "$group" "$id" >&2; rc=1; }
        _nftban_rbl_reg_in "$state" "$_NFTBAN_RBL_REG_STATE"    || { printf 'nftban: rbl registry: invalid state %q in [%s]\n' "$state" "$id" >&2; rc=1; }
        [[ "$audit" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]          || { printf 'nftban: rbl registry: audit_date must be ISO YYYY-MM-DD in [%s] (got %q)\n' "$id" "$audit" >&2; rc=1; }
        [[ "$conf" =~ ^[A-Z][A-Z_]*$ ]]                         || { printf 'nftban: rbl registry: confidence must be an UPPER_TOKEN in [%s] (got %q)\n' "$id" "$conf" >&2; rc=1; }
        [[ "$op" =~ ^[A-Z][A-Z0-9_]*$ ]]                        || { printf 'nftban: rbl registry: operational_status must be an UPPER_TOKEN in [%s] (got %q)\n' "$id" "$op" >&2; rc=1; }
        # license must be present (UNVERIFIED is first-class; never inferred permitted)
        [[ -n "$lic" ]]                                         || { printf 'nftban: rbl registry: license required (use UNVERIFIED) in [%s]\n' "$id" >&2; rc=1; }
        [[ -n "$repl" ]] && repl_edges+="${id}>${repl}"$'\n'
    done <<< "$records"
    # RBL code runs under IFS=$'\n\t' (no space-splitting) — edges are newline-
    # delimited and iterated with `read`, never `for x in $var`.
    local e t src cur nxt depth e2
    while IFS= read -r e; do
        [[ -z "$e" ]] && continue
        t="${e#*>}"
        if [[ "$t" == EXTERNAL:* ]]; then
            _nftban_rbl_reg_is_dnsname "${t#EXTERNAL:}" || { printf 'nftban: rbl registry: EXTERNAL replacement %q is not a dns name\n' "$t" >&2; rc=1; }
        elif [[ "$decl_zone" != *" $t "* && "$decl_id" != *" $t "* ]]; then
            printf 'nftban: rbl registry: replacement %q does not resolve to a declared record or EXTERNAL:<zone>\n' "$t" >&2; rc=1
        fi
    done <<< "$repl_edges"
    while IFS= read -r e; do
        [[ -z "$e" ]] && continue
        src="${e%%>*}"; t="${e#*>}"; [[ "$t" == EXTERNAL:* ]] && continue
        cur="$t"; depth=0
        while [[ -n "$cur" ]]; do
            [[ "$cur" == "$src" ]] && { printf 'nftban: rbl registry: cyclic replacement chain at %q\n' "$src" >&2; rc=1; break; }
            depth=$((depth+1)); [[ $depth -gt 32 ]] && { printf 'nftban: rbl registry: replacement chain too deep from %q\n' "$src" >&2; rc=1; break; }
            nxt=""
            while IFS= read -r e2; do
                [[ -z "$e2" ]] && continue
                if [[ "${e2%%>*}" == "$cur" ]]; then nxt="${e2#*>}"; [[ "$nxt" == EXTERNAL:* ]] && nxt=""; break; fi
            done <<< "$repl_edges"
            cur="$nxt"
        done
    done <<< "$repl_edges"
    return $rc
}

# Typed records for the CURRENT effective provider set. Membership + order come
# from the authoritative legacy loader (rbls.conf). When a VALID registry data
# file is present, each zone's registry record is OVERLAID (metadata only); a
# zone with no registry record — or any invalid registry — falls back to the
# conservative legacy projection. NEVER changes membership, order, or count.
nftban_rbl_registry_records() {
    local reg="" have_reg=0
    if [[ -f "$NFTBAN_RBL_REGISTRY_FILE" ]] && nftban_rbl_registry_validate "$NFTBAN_RBL_REGISTRY_FILE" >/dev/null 2>&1; then
        reg="$(nftban_rbl_registry_parse "$NFTBAN_RBL_REGISTRY_FILE" 2>/dev/null)"; have_reg=1
    fi
    local line domain url match
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        domain="${line%%:*}"; url="${line#*:}"; [[ "$url" == "$line" ]] && url=""
        match=""
        [[ $have_reg -eq 1 ]] && match="$(printf '%s\n' "$reg" | awk -F'\t' -v z="$domain" '$2==z{print; exit}')"
        if [[ -n "$match" ]]; then
            printf '%s\n' "$match"
        else
            nftban_rbl_registry_legacy_record "$domain" "$url"
        fi
    done < <(nftban_rbl_load_providers)
}

# Effective provider list (domain:url) — the flat-list-compatibility bridge.
# GUARANTEE: byte-identical to nftban_rbl_load_providers. rbls.conf is
# authoritative; the registry supplies metadata only and NEVER changes the set.
nftban_rbl_registry_effective() {
    if [[ -f "$NFTBAN_RBL_REGISTRY_FILE" ]]; then
        if ! nftban_rbl_registry_validate "$NFTBAN_RBL_REGISTRY_FILE" >/dev/null 2>&1; then
            printf 'nftban: rbl registry: %s is invalid — ignoring it; using authoritative rbls.conf\n' \
                "$NFTBAN_RBL_REGISTRY_FILE" >&2
        fi
    fi
    nftban_rbl_load_providers
}

# ---- read-only inspection helpers (slice 2/3A; no state change) -------------

nftban_rbl_registry_get() {
    local want="$1" line
    while IFS= read -r line; do
        [[ "${line%%$'\t'*}" == "$want" ]] && { printf '%s\n' "$line"; return 0; }
    done < <(nftban_rbl_registry_records)
    return 1
}

# Live RFC5782 reachability probe FROM the operator's resolver. Read-only
# diagnostic — changes NO state, issues NO ban. Timeout != NXDOMAIN.
nftban_rbl_registry_test_zone() {
    local zone="$1" timeout="${NFTBAN_RBL_TIMEOUT:-4}" out st
    command -v dig >/dev/null 2>&1 || { printf 'NO_RESOLVER_TOOL'; return 0; }
    out="$(dig +time="$timeout" +tries=1 A "2.0.0.127.${zone}" 2>/dev/null)"
    [[ -z "$out" ]] && { printf 'TIMEOUT'; return 0; }
    st="$(printf '%s\n' "$out" | sed -n 's/.*status: \([A-Z]*\),.*/\1/p' | head -1)"
    case "$st" in
        NOERROR)
            if printf '%s\n' "$out" | grep -qE '[[:space:]]IN[[:space:]]+A[[:space:]]+127\.'; then printf 'LISTED_TESTPOINT'; else printf 'REACHABLE_NOANSWER'; fi ;;
        NXDOMAIN) printf 'CLEAN' ;;
        REFUSED)  printf 'REFUSED' ;;
        SERVFAIL) printf 'SERVFAIL' ;;
        "")       printf 'TIMEOUT' ;;
        *)        printf '%s' "$st" ;;
    esac
}

export -f nftban_rbl_registry_get nftban_rbl_registry_test_zone 2>/dev/null || true
export -f nftban_rbl_registry_legacy_record nftban_rbl_registry_parse nftban_rbl_registry_validate 2>/dev/null || true
export -f nftban_rbl_registry_records nftban_rbl_registry_effective 2>/dev/null || true
export -f _nftban_rbl_reg_in _nftban_rbl_reg_safe _nftban_rbl_reg_is_dnsname _nftban_rbl_reg_trim 2>/dev/null || true
