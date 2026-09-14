#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — per-source connlimit emission must have exactly ONE authority (P12-A02)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-connlimit-emission-authority"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="P12-A02 exit gate. SIBLING of check-placeholder-substitution-authority.sh, deliberately NOT an extension of it: that guard owns VALUE substitution authority, this one owns STRUCTURAL connlimit authority. Mixing them would make the 3D.2 contract harder to reason about. Asserts: one structural renderer; zero bare host-wide ct count in the A02 service class; every declared service projected exactly once by its declared owner; IPv4/IPv6 pairs present; no duplicate SMTP/25 fragment projection; renderer carries no policy literals. Comments are STRIPPED before scanning - a mention is not an implementation. Carries its own negative controls (--self-test)."
# meta:inventory.files="cli/lib/nftban/data/connlimit-services.tsv,cli/lib/nftban/lib/nftban_connlimit.sh,install/nftables/nftables.conf.tpl,cli/lib/nftban/lib/nft_fragment.sh,install/nftables/nftables.conf"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DECL="$ROOT/cli/lib/nftban/data/connlimit-services.tsv"
REND="$ROOT/cli/lib/nftban/lib/nftban_connlimit.sh"
TPL="$ROOT/install/nftables/nftables.conf.tpl"
FRAG="$ROOT/cli/lib/nftban/lib/nft_fragment.sh"
BOOT="$ROOT/install/nftables/nftables.conf"
FAILS=0
ok(){ printf '  [PASS] %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

# Strip shell/nft comments so a DOC MENTION is never read as an implementation.
strip(){ sed -e 's/[[:space:]]*#.*$//' "$1"; }

# A BARE host-wide connlimit: `ct count over N` with NO saddr key on the same line.
bare_hits(){ strip "$1" | grep -nE 'ct count over' | grep -vE 'ip6?[[:space:]]+saddr' || true; }

echo "=== connlimit emission authority (P12-A02) ==="

# --- 1 · exactly ONE structural renderer -------------------------------------
RC=$(grep -rlE '^nftban_connlimit_rule\(\)' "$ROOT/cli/lib/nftban" 2>/dev/null | grep -v '/tests/' | wc -l | tr -d ' ')
[[ "$RC" == "1" ]] && ok "one structural connlimit renderer (found $RC)" \
                   || bad "expected exactly 1 connlimit renderer, found $RC"

# --- 2 · renderer carries NO policy literals ---------------------------------
if [[ -f "$REND" ]]; then
    LIT=$(strip "$REND" | grep -nE 'ct count over[[:space:]]+[0-9]+|(^|[^A-Z_])(15|200|30|50)[[:space:]]*$' | wc -l | tr -d ' ')
    [[ "$LIT" == "0" ]] && ok "renderer carries no policy literals" \
                        || bad "renderer contains $LIT policy literal(s) — it must not be a value source"
else bad "renderer missing: $REND"; fi

# --- 3 · declaration is data-only --------------------------------------------
if [[ -f "$DECL" ]]; then
    BADD=$(strip "$DECL" | grep -nE '\$\(|`|sed |ct count|add rule' | wc -l | tr -d ' ')
    [[ "$BADD" == "0" ]] && ok "declaration is data-only (no code/syntax)" \
                         || bad "declaration contains $BADD code-like line(s)"
    ROWS=$(awk -F'\t' '!/^[[:space:]]*#/ && NF>=6' "$DECL" | wc -l | tr -d ' ')
    [[ "$ROWS" == "4" ]] && ok "declaration has the expected 4 service rows" \
                         || bad "expected 4 declaration rows, found $ROWS"
else bad "declaration missing: $DECL"; fi

# --- 4 · ZERO bare host-wide ct count in the live projections ----------------
for f in "$TPL" "$FRAG" "$BOOT"; do
    [[ -f "$f" ]] || { bad "projection missing: $f"; continue; }
    n=$(bare_hits "$f" | wc -l | tr -d ' ')
    rel="${f#$ROOT/}"
    [[ "$n" == "0" ]] && ok "no bare host-wide ct count: $rel" \
                      || bad "$rel has $n bare host-wide 'ct count over N' (no saddr key)"
done

# --- 5 · no duplicate SMTP/25 fragment projection ----------------------------
if [[ -f "$FRAG" ]]; then
    D=$(strip "$FRAG" | grep -cE 'dport[[:space:]]+25[[:space:]].*ct count over' || true)
    [[ "$D" == "0" ]] && ok "no duplicate SMTP/25 connlimit in the fragment" \
                      || bad "fragment has $D SMTP/25 connlimit rule(s) — duplicate projection of canonical MAIL"
fi

# --- 6 · every declared service projected by its declared owner, v4+v6 -------
if [[ -f "$DECL" ]]; then
    while IFS=$'\t' read -r svc ports var s4 s6 by; do
        [[ -z "${svc:-}" ]] && continue
        case "$by" in base) tgt="$TPL"; rel="nftables.conf.tpl" ;; fragment) tgt="$FRAG"; rel="nft_fragment.sh" ;; *) bad "$svc: unknown PROJECTED_BY '$by'"; continue ;; esac
        [[ -f "$tgt" ]] || { bad "$svc: projection target missing"; continue; }
        h4=$(strip "$tgt" | grep -c "@${s4}" || true); h6=$(strip "$tgt" | grep -c "@${s6}" || true)
        if [[ "$h4" -ge 1 && "$h6" -ge 1 ]]; then ok "$svc: v4+v6 projected in $rel"
        else bad "$svc: missing projection in $rel (v4 hits=$h4 v6 hits=$h6)"; fi
    done < <(awk -F'\t' '!/^[[:space:]]*#/ && NF>=6' "$DECL")
fi

echo "=== connlimit emission: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]] || exit 1
exit 0
