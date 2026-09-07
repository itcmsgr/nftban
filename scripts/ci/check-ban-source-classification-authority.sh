#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — LANE-BST: one ban-source classification / storage-routing authority
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-ban-source-classification-authority"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-07"
# meta:description="v1.229.13 LANE-BST. A ban's STORAGE CLASS must derive from the canonical Kind in internal/bansource, never from the spelling of the raw source string. Before this lane at least four independent predicates interpreted that string and disagreed — on OPPOSITE defaults — which silently routed detector bans into the feed-owned interval sets where the next synchronisation erased them. This guard fails the build if a second storage-routing classifier reappears. Comments are stripped first: describing the retired pattern is not implementing it."
# meta:inventory.files="internal/bansource/bansource.go,internal/nftbackend/backend.go,internal/opqueue/types.go"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc=0
ok(){ printf '  PASS  %s\n' "$1"; }
bad(){ rc=1; printf '  FAIL  %s\n' "$1"; }

CANON="$ROOT/internal/bansource/bansource.go"
strip_go_comments(){ sed -e 's://.*::' "$1" | perl -0pe 's{/\*.*?\*/}{}gs'; }

echo "== subject population (non-vacuity asserted first) =="
[[ -f "$CANON" ]] || { bad "canonical authority missing: internal/bansource/bansource.go"; exit 1; }
GO_FILES=$(find "$ROOT/internal" "$ROOT/cmd" -name '*.go' -not -name '*_test.go' 2>/dev/null | wc -l)
[[ "$GO_FILES" -gt 0 ]] || { bad "zero Go files scanned — a guard over nothing is a false green"; exit 1; }
ok "canonical authority present; $GO_FILES product Go files in scope"

echo "== CANONICAL_BAN_SOURCE_AUTHORITY == 1 =="
DEFS=$(grep -rlE '^func Resolve\(raw string, origin Origin\) Kind' "$ROOT/internal" 2>/dev/null | wc -l)
if [[ "$DEFS" -eq 1 ]]; then ok "exactly one Resolve() classification authority"
else bad "found $DEFS Resolve() definitions — want exactly 1"; fi

echo "== the retired exact-match predicate must not return =="
# isManualSource was the switch that decided storage from spelling.
HITS=""
while IFS= read -r f; do
    case "$f" in "$CANON") continue;; esac
    out=$(strip_go_comments "$f" | grep -nE 'func isManualSource' || true)
    [[ -n "$out" ]] && HITS+="${f#$ROOT/}: $out"$'\n'
done < <(find "$ROOT/internal" "$ROOT/cmd" -name '*.go' 2>/dev/null)
if [[ -z "$HITS" ]]; then ok "isManualSource() has not reappeared"
else bad "the retired spelling-based storage predicate is back:"; printf '%s' "$HITS" | sed 's/^/        /'; fi

echo "== STORAGE_ROUTING_AUTHORITIES == 1 =="
# ⛔ SCOPE OF THIS CHECK, stated honestly. "No file anywhere may ever select storage
# from a source string" is not syntactically decidable: many files legitimately NAME
# these sets — an evidence name-list, a set-membership map, the sync authority
# obtaining the handle it owns, a named constant. An earlier draft of this guard
# flagged all of those and would have forced a false invariant onto the codebase.
# So this pins the KNOWN routing sites instead: both must consult the canonical
# authority. That is provable; universality is not.
ROUTERS=(
    "internal/nftbackend/backend.go"
    "internal/opqueue/types.go"
)
for rel in "${ROUTERS[@]}"; do
    f="$ROOT/$rel"
    if [[ ! -f "$f" ]]; then bad "known routing site missing: $rel"; continue; fi
    body=$(strip_go_comments "$f")
    if [[ "$(printf '%s' "$body" | grep -c 'bansource\.' || true)" -gt 0 ]]; then
        ok "$rel consults the canonical authority"
    else
        bad "$rel selects blacklist storage WITHOUT consulting internal/bansource — \
a second routing table is how detector bans were routed into the feed-owned interval \
sets and erased by feed sync"
    fi
done

echo "== RAW_SOURCE_DIRECTLY_DECIDES_STORAGE == NO =="
if [[ "$(strip_go_comments "$CANON" | grep -cE 'func UsesReplaceManagedStorage\(k Kind\) bool' || true)" -gt 0 ]]; then
    ok "the storage predicate takes a Kind, not a string"
else
    bad "UsesReplaceManagedStorage must take a Kind — taking a string would reinstate \
spelling-decides-storage"
fi

# --------------------------------------------------------------- self-test
if [[ "${1:-}" == "--self-test" ]]; then
    echo "== NEGATIVE CONTROL =="
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/internal/fake"
    cat > "$TMP/internal/fake/second.go" <<'INJ'
package fake

func route(source string) string {
	if source == "manual" {
		return "blacklist_manual_ipv4"
	}
	return "blacklist_ipv4"
}
INJ
    # Inversion: strip the authority reference from a known router and confirm detection.
    cp "$ROOT/internal/opqueue/types.go" "$TMP/types.go.orig"
    sed 's/bansource\./REMOVED_/g' "$ROOT/internal/opqueue/types.go" > "$TMP/types_nc.go"
    if [[ "$(strip_go_comments "$TMP/types_nc.go" | grep -c 'bansource\.' || true)" -gt 0 ]]; then
        bad "NEGATIVE CONTROL FAILED — could not construct the inversion"
    else
        ok "NEGATIVE CONTROL: a router stripped of the authority reference IS detected"
    fi
    cat > "$TMP/internal/fake/mention.go" <<'INJ'
package fake

// Historically this chose blacklist_manual_ipv4 by comparing the source string.
func fine() {}
INJ
    body2=$(strip_go_comments "$TMP/internal/fake/mention.go")
    if [[ "$(printf '%s' "$body2" | grep -c 'blacklist_manual_ipv4' || true)" -gt 0 ]]; then
        bad "NEGATIVE CONTROL FAILED — guard flags a COMMENT, not an implementation"
    else
        ok "NEGATIVE CONTROL: a comment-only mention is NOT flagged"
    fi
fi
exit "$rc"
