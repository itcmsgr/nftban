#!/usr/bin/env bash
# =============================================================================
# NFTBan - do not rewrite an UNBOUNDED nft payload to answer a boolean (G2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-unbounded-payload-rewrite"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:created_date="2026-09-03"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="BLOCKING. Forbids ${var//[[:space:]]/} and ${var//[[:blank:]]/} where var was captured from an nft subcommand that DUMPS CONTENTS. Such a rewrite allocates a full transformed copy of an unbounded payload purely to answer a boolean; measured at 1.1-2.3 s per call on live 20-43 KB lab rulesets and 14.0 s on a 50k-element set dump. The bounded replacement is nftban_has_non_whitespace in lib/shell_predicates.sh. The discriminator is STRUCTURAL, not a variable-name heuristic: nft's SINGULAR object subcommands (list ruleset/table/set/chain/map) dump contents and are unbounded, while the PLURAL ones (list tables/sets/chains/maps) list names and are bounded by object count. A name heuristic would risk false negatives, which are worse than false positives here."
# meta:input="every *.sh under cli/lib/nftban excluding tests/"
# meta:output="PASS/FAIL per site; exit 1 on any violation. NO allow-list exists by design."
# meta:inventory.files="cli/lib/nftban/lib/shell_predicates.sh"
# meta:inventory.privileges="none"
#
# ⛔ THERE IS NO `.allow` FILE, DELIBERATELY. Every historical match was either a
#    real defect (15, all remediated in v1.229.13 Lane 2B) or a bounded payload
#    that this matcher does not fire on. An allow entry would be a standing
#    declaration that an unbounded rewrite is acceptable somewhere; none is.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

# nft subcommands that DUMP CONTENTS -> payload grows with rules/elements.
UNBOUNDED='list (ruleset|table|set|chain|map|flowtable)[[:space:]]'
# Their plural siblings list NAMES only and are bounded by object count:
#   list tables / list sets / list chains / list maps
# `list ruleset` takes no object argument, so it is matched separately.

FAIL=0
SITES=0
SELF="$(realpath "${BASH_SOURCE[0]}")"

# For each rewrite-in-a-test, walk BACKWARDS within the same function to find how
# the variable was captured. A bounded backward scan, not a fixed lookback: an
# earlier attempt at this used a 3-line window and misclassified 4 of 7 sites
# because it could not see the `if VAR=$(...) && ...` idiom.
scan_file() {
    local f="$1"
    [[ "$(realpath "$f")" == "$SELF" ]] && return 0
    awk -v file="$f" -v unbounded="$UNBOUNDED" '
        # remember the most recent assignment of each variable
        {
            line[NR] = $0
        }
        END {
            for (n = 1; n <= NR; n++) {
                l = line[n]
                # only the TEST form; a bare assignment `x=${x//...}` is a
                # transformation, not a predicate, and is out of scope.
                # BOTH POSIX classes. `[[:blank:]]` is the same antipattern with the
                # same cost; matching only [[:space:]] would be a FALSE NEGATIVE, and
                # the register is explicit that those are worse than false positives.
                if (l !~ /\[\[[^]]*\$\{[A-Za-z_][A-Za-z0-9_]*\/\/\[\[:(space|blank):\]\]\/\}/) continue
                if (match(l, /\$\{[A-Za-z_][A-Za-z0-9_]*\/\/\[\[:(space|blank):\]\]\/\}/) == 0) continue
                v = substr(l, RSTART + 2, RLENGTH - 2)
                sub(/\/\/.*$/, "", v)
                # walk back to the enclosing function start, or 200 lines
                lo = (n > 200) ? n - 200 : 1
                src = ""
                for (m = n; m >= lo; m--) {
                    p = line[m]
                    if (p ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ && m < n) break
                    if (p ~ ("(^|[^A-Za-z0-9_])" v "=")) {
                        if (p ~ /nft[[:space:]]/ && (p ~ unbounded || p ~ /list ruleset/)) { src = p }
                        break
                    }
                }
                if (src != "") {
                    printf "%s:%d: rewrites an UNBOUNDED nft payload ($%s) to answer a boolean\n", file, n, v
                    printf "    %s\n", gensub(/^[[:space:]]+/, "", 1, l)
                    printf "    captured by: %s\n", gensub(/^[[:space:]]+/, "", 1, src)
                    printf "    use: nftban_has_non_whitespace \"$%s\"  (lib/shell_predicates.sh)\n", v
                    printf "VIOLATION\n"
                }
            }
        }
    ' "$f"
}

echo "=== check-unbounded-payload-rewrite (G2, BLOCKING, no allow-list) ==="
while IFS= read -r f; do
    out="$(scan_file "$f")"
    [[ -z "$out" ]] && continue
    n="$(grep -c '^VIOLATION$' <<<"$out")"
    SITES=$(( SITES + n ))
    grep -v '^VIOLATION$' <<<"$out"
    FAIL=1
done < <(find cli/lib/nftban -name '*.sh' -not -path '*/tests/*' | sort)

if (( FAIL == 0 )); then
    echo "PASS: KNOWN_VIOLATIONS=0 — no unbounded nft payload is rewritten to answer a boolean"
else
    echo "FAIL: $SITES site(s) rewrite an unbounded nft payload for a boolean"
    echo "      There is NO allow-list. Replace the rewrite with nftban_has_non_whitespace,"
    echo "      preserving the site's rc branch and its UNKNOWN semantics unchanged."
fi
exit $FAIL
