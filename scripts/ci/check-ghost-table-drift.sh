#!/usr/bin/env bash
# =============================================================================
# NFTBan — ghost-table identity drift guard (v1.228.11)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# v1.228.11 fixed the SAME by-name deletion defect in two languages. The Go
# ghostTables[] and the shell _NFTBAN_GHOST_TABLE_IDENTITIES are consumed by
# independent code paths, so nothing structurally prevents one from gaining a
# name the other lacks — which is how the pre-fix asymmetry arose (`inet filter`
# was Class-3-protected in Go while the shell deleted it unconditionally).
#
# Compares the two SEMANTICALLY (sorted set equality), not textually.
# Exit 0 = in sync · 1 = drift · 2 = tool failure (fail closed).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GO_SRC="$ROOT/internal/installer/switchop/ghost.go"
SH_SRC="$ROOT/cli/lib/nftban/core/nftban_table_classify.sh"
[[ -f "$GO_SRC" && -f "$SH_SRC" ]] || { echo "FAIL: source(s) missing"; exit 2; }

# NOTE: the range must end at a line that is EXACTLY "}" — the struct literal
# opens with "}{", and an earlier version of this guard ended there, extracting
# zero entries. It failed CLOSED (exit 2) rather than passing vacuously, which is
# why that bug was caught instead of silently disabling the check.
go_list="$(awk '/^var ghostTables = \[\]struct/,/^\}$/' "$GO_SRC" \
  | grep -oE '\{"[a-z0-9]+", *"[a-z0-9_]+"\}' \
  | sed -E 's/\{"([a-z0-9]+)", *"([a-z0-9_]+)"\}/\1 \2/' | sort -u)"
sh_list="$(awk '/_NFTBAN_GHOST_TABLE_IDENTITIES=\(/,/^\)/' "$SH_SRC" \
  | grep -oE '"[a-z0-9]+ [a-z0-9_]+"' | tr -d '"' | sort -u)"

# Go handles `inet filter` in Class 3 (cleanInetFilter) rather than the Class-1
# ghostTables[] array — it gets STRONGER protection there (populated requires
# NFTBAN_ALLOW_REMOVE_INET_FILTER=1). It is nonetheless a known ghost identity,
# so the EFFECTIVE Go identity set includes it. Verified structurally below so
# this exception cannot silently mask a real removal of that handling.
if grep -q 'func cleanInetFilter' "$GO_SRC"; then
    go_list="$(printf '%s\ninet filter\n' "$go_list" | grep -vE '^$' | sort -u)"
else
    echo "FAIL: cleanInetFilter missing — the inet filter exception is no longer valid"; exit 2
fi

[[ -n "$go_list" ]] || { echo "FAIL: could not extract Go list (parser broken)"; exit 2; }
[[ -n "$sh_list" ]] || { echo "FAIL: could not extract shell list (parser broken)"; exit 2; }

if [[ "$go_list" == "$sh_list" ]]; then
    echo "ghost-table identity drift: NONE ($(echo "$go_list" | wc -l) identities in sync)"
    exit 0
fi
echo "FAIL: ghost-table identity DRIFT between Go and shell"
echo "--- only in Go ---";    comm -23 <(echo "$go_list") <(echo "$sh_list") | sed 's/^/  /'
echo "--- only in shell ---"; comm -13 <(echo "$go_list") <(echo "$sh_list") | sed 's/^/  /'
exit 1
