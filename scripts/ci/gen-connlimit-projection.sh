#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# P12-A02 CONNLIMIT PROJECTION GENERATOR
# =============================================================================
# meta:description="Renders the per-source connlimit block for ONE projection
#   medium from the canonical declaration (data/connlimit-services.tsv) via the
#   single structural renderer (lib/nftban_connlimit.sh). This script is the
#   ADAPTER: it owns medium-specific WRAPPING and SCOPE only. It carries NO nft
#   syntax of its own and NO policy values.
#
#   MEDIA
#     base-sets   declarative TABLE scope  — dynamic sets are table-level objects
#                 and CANNOT be declared inside a chain body, so they are emitted
#                 separately from the rules that use them.
#     base-rules  declarative CHAIN scope  — one indent deeper, inside `chain input`.
#     fragment    imperative — `nft -f` against a LIVE ruleset, so every statement
#                 needs its own verb and an explicit table/chain target.
#
#   Limit values are NEVER resolved here. Each medium has its own scalar token,
#   derived from the service name, and the existing scalar substitution layer
#   fills it in later:
#     base-*    -> __CT_LIMIT_<UPPER>__   (_firewall_substitute_placeholders)
#     fragment  -> \${<service>_limit}     (shell expansion in nft_fragment.sh)
#   That keeps _firewall_substitute_placeholders() scalar-only and leaves the
#   template the canonical structural owner, per the frozen A02 ruling."
#
# Usage: gen-connlimit-projection.sh <base-sets|base-rules> <4|6>
#        gen-connlimit-projection.sh fragment
#
# The declarative media REQUIRE a family: the template carries a separate
# `table ip nftban` and `table ip6 nftban` block, so an ipv6_addr set emitted
# into the ip table is a type error, not a cosmetic one. The fragment medium
# targets both families in one file because each statement names its own table.
# Exit:  0 emitted · 2 usage/unknown medium · 3 declaration or renderer missing
# =============================================================================
set -Eeuo pipefail

MEDIUM="${1:-}"
FAMILY="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DECL="$ROOT/cli/lib/nftban/data/connlimit-services.tsv"
REND="$ROOT/cli/lib/nftban/lib/nftban_connlimit.sh"

case "$MEDIUM" in
    base-sets|base-rules)
        case "$FAMILY" in
            4|6) ;;
            *) echo "usage: ${0##*/} $MEDIUM <4|6>  (family is required)" >&2; exit 2 ;;
        esac
        ;;
    fragment)
        # Family is OPTIONAL here: the fragment names its own table per statement
        # so both families can share one file, but the projection is spliced into
        # per-family marker blocks, so the applier asks for one family at a time.
        case "${FAMILY:-}" in
            ''|4|6) ;;
            *) echo "usage: ${0##*/} fragment [4|6]" >&2; exit 2 ;;
        esac
        ;;
    *) echo "usage: ${0##*/} <base-sets|base-rules|fragment>" >&2; exit 2 ;;
esac

[[ -f "$DECL" ]] || { echo "MISSING declaration: $DECL" >&2; exit 3; }
[[ -f "$REND" ]] || { echo "MISSING renderer: $REND" >&2; exit 3; }
# shellcheck source=/dev/null
source "$REND"

# The renderer is the ONLY source of nft syntax. Fail loudly if it is not the
# shape we depend on, rather than emitting a silently wrong block.
for fn in nftban_connlimit_set_decl nftban_connlimit_rule; do
    declare -F "$fn" >/dev/null || { echo "RENDERER missing $fn" >&2; exit 3; }
done

# base-sets and base-rules are two SCOPES of the same declaration rows.
WANT_PROJECTION="${MEDIUM%%-*}"

emitted=0
while IFS=$'\t' read -r service ports _var set_v4 set_v6 projection; do
    [[ -z "${service:-}" || "$service" == \#* ]] && continue
    [[ "$projection" == "$WANT_PROJECTION" ]] || continue

    upper="${service^^}"
    if [[ "$MEDIUM" == base-* ]]; then
        limit_token="__CT_LIMIT_${upper}__"
    else
        limit_token="\${${service}_limit}"
    fi

    for fam in 4 6; do
        [[ -n "$FAMILY" && "$fam" != "$FAMILY" ]] && continue
        if [[ "$fam" == 4 ]]; then set_name="$set_v4"; tbl='${table_ipv4}'
        else                       set_name="$set_v6"; tbl='${table_ipv6}'; fi

        decl=$(nftban_connlimit_set_decl "$set_name" "$fam")

        # Named counters are DECLARATIVE-MEDIUM observability, not part of the
        # connlimit primitive. The template declares counter input_ct_<svc>_drop
        # and total_input_drop, and two independent authorities assert they are
        # present on these rules (lib/nft_schema.sh:1199-1201 and
        # tests/nft_crosscheck.sh:193-195). Emitting without them would be a
        # silent observability regression that those checks would — correctly —
        # fail on. The fragment medium declares no such counters, so it gets the
        # bare frozen primitive.
        if [[ "$MEDIUM" == base-rules ]]; then
            counter_clause="counter name input_ct_${service}_drop counter name total_input_drop"
        else
            # The fragment's existing rules count into total_input_drop, which is
            # declared by the base table the fragment attaches to. Preserve it:
            # dropping it here would quietly break drop accounting for DNS.
            counter_clause="counter name total_input_drop counter"
        fi

        rule=$(nftban_connlimit_rule "$set_name" "$fam" "$ports" "$limit_token" "$counter_clause")

        case "$MEDIUM" in
            base-sets)
                # Reformat the renderer's one-line declaration into the template's
                # multi-line block style. This is NOT cosmetic: the bounded-limiter
                # guard's template scanner (scripts/ci/check-nft-bounded-limiters.sh
                # R5) is a state machine keyed on `set NAME {` ... `}` across LINES,
                # so a one-line declaration is INVISIBLE to it and a new limiter
                # would silently escape its at-capacity policy requirement. The
                # renderer remains the only source of the type/flags text — this
                # only re-wraps it.
                set_body="${decl#*\{}"; set_body="${set_body%\}*}"
                printf '    set %s {\n' "$set_name"
                printf '%s' "$set_body" | tr ';' '\n' | while IFS= read -r attr; do
                    attr="${attr#"${attr%%[![:space:]]*}"}"
                    attr="${attr%"${attr##*[![:space:]]}"}"
                    [[ -n "$attr" ]] && printf '        %s\n' "$attr"
                done
                printf '    }\n'
                ;;
            base-rules)
                printf '        %s comment "%s: max %s concurrent PER SOURCE"\n' \
                    "$rule" "$upper" "$limit_token"
                ;;
            fragment)
                printf 'add %s %s %s\n' "${decl%% *}" "$tbl" "${decl#* }"
                printf 'add rule %s ${chain} %s comment "%s: max %s concurrent PER SOURCE"\n' \
                    "$tbl" "$rule" "$upper" "$limit_token"
                ;;
        esac
        emitted=$((emitted + 1))
    done
done < <(grep -v '^[[:space:]]*#' "$DECL" | grep -v '^[[:space:]]*$')

[[ "$emitted" -gt 0 ]] || { echo "NO rows projected for medium=$MEDIUM family=${FAMILY:-both}" >&2; exit 3; }
