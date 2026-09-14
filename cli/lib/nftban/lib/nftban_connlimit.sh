#!/usr/bin/env bash
# =============================================================================
# NFTBan - PER-SOURCE CONNLIMIT EMISSION AUTHORITY (P12-A02)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_connlimit"
# meta:type="lib"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="P12-A02 THE single structural authority for per-source connection limits. Owns nft connlimit SYNTAX ONLY. Receives service/ports/limit/set names from the canonical declaration (data/connlimit-services.tsv) and the numeric value from the caller; it is NOT a policy source and carries NO fallback literals. Emits declarative nft text (set + keyed rule); media-specific wrapping (e.g. 'add rule') is the CONSUMER's responsibility. Primitive frozen after lab proof on nftables 1.0.9 and 1.1.6 across kernels 5.14/6.8/7.0: 'ct count over N' admits exactly N concurrent per source, IPv4 and IPv6 behaviourally symmetric."
# meta:inventory.files="cli/lib/nftban/lib/nftban_connlimit.sh,cli/lib/nftban/data/connlimit-services.tsv"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.privileges="none"
# =============================================================================
#
# ⛔ THIS FILE MUST NOT CONTAIN POLICY. No fallback limits (15 / 200 / 30 / 50).
#    conf.d/ddos/classic.conf via DDOS_CLASSIC_*_CONN_LIMIT is the ONLY value authority.
#
# ⛔ THIS FILE MUST NOT SUBSTITUTE PLACEHOLDERS. Scalar substitution belongs to
#    _firewall_substitute_placeholders() (v1.229.13 Lane 3D.2, mechanically fenced by
#    scripts/ci/check-placeholder-substitution-authority.sh). Structure here, values there.
#
# ⛔ THIS FILE MUST NOT POPULATE SET MEMBERS. The emitted sets are `flags dynamic`;
#    nftables creates their members at packet evaluation. @ssh_ports is REFERENCED
#    only — its membership stays owned by _firewall_set_elements() and the Go
#    ensureSSHPortsInSet path.
#
# THE FROZEN PRIMITIVE
#   set <name> { type ipv4_addr|ipv6_addr ; flags dynamic }
#   ct state new tcp dport <ports> add @<name> { ip|ip6 saddr ct count over N } counter drop
#   add (NOT update) · NO timeout — conntrack owns capacity lifetime; the set element
#   persists after connections drain WITHOUT preserving consumed capacity (lab-proven).
# =============================================================================
[[ -n "${NFTBAN_CONNLIMIT_LOADED:-}" ]] && return 0
NFTBAN_CONNLIMIT_LOADED=true

: "${NFTBAN_CONNLIMIT_DECL:=${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data/connlimit-services.tsv}"

# nftban_connlimit_decl_rows [projected_by]
# Emits declaration rows (TAB-separated), optionally filtered by PROJECTED_BY.
# Parsed with awk, never `read`: a whitespace-splitting read pass mis-handles these rows.
nftban_connlimit_decl_rows() {
    local want="${1:-}"
    [[ -r "$NFTBAN_CONNLIMIT_DECL" ]] || return 1
    awk -F'\t' -v w="$want" '
        /^[[:space:]]*#/ { next }
        NF < 6           { next }
        w == "" || $6 == w { print }
    ' "$NFTBAN_CONNLIMIT_DECL"
}

# nftban_connlimit_set_decl <set_name> <family:4|6>
# The SET half of the primitive. Declarative nft text; no medium assumptions.
nftban_connlimit_set_decl() {
    local set_name="$1" fam="$2" type
    case "$fam" in
        4) type="ipv4_addr" ;;
        6) type="ipv6_addr" ;;
        *) return 2 ;;
    esac
    printf 'set %s { type %s; flags dynamic; }\n' "$set_name" "$type"
}

# nftban_connlimit_rule <set_name> <family:4|6> <port_expr> <limit> [counter_clause]
# The RULE half. `add` not `update`; no timeout. The caller supplies the RESOLVED
# numeric limit — this function never reads configuration and never defaults.
#
# counter_clause (optional) is the CONSUMER's observability wrapping, inserted
# verbatim before the verdict. It exists because the declarative template carries
# NAMED counters that other authorities assert on — nft_schema.sh:1199-1201 and
# tests/nft_crosscheck.sh:193-195 both require input_ct_{ssh,http,mail}_drop to be
# present — while the fragment medium carries none. Counter NAMES are an emission
# concern of the medium, not a property of the connlimit primitive, so they are
# passed in rather than derived here. Omitted => bare `counter`, which is the
# frozen primitive exactly as proven on nftables 1.0.9 and 1.1.6.
nftban_connlimit_rule() {
    local set_name="$1" fam="$2" ports="$3" limit="$4" counters="${5-counter}" addr
    case "$fam" in
        4) addr="ip saddr" ;;
        6) addr="ip6 saddr" ;;
        *) return 2 ;;
    esac
    [[ -n "$limit" ]] || return 3   # ⛔ fail closed: no limit => no rule, never a default
    # ${5-counter}: only an OMITTED argument gets the default. An argument that is
    # PRESENT BUT EMPTY is a caller bug (an unset variable) and must not silently
    # render a different rule than the caller believed they asked for.
    [[ -n "$counters" ]] || return 4
    printf 'ct state new tcp dport %s add @%s { %s ct count over %s } %s drop\n' \
        "$ports" "$set_name" "$addr" "$limit" "$counters"
}
