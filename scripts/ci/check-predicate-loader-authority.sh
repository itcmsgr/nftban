#!/usr/bin/env bash
# =============================================================================
# NFTBan - every caller of nftban_has_non_whitespace must be able to load it
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# WHY THIS GUARD EXISTS
# ---------------------
# Every consumer of lib/shell_predicates.sh soft-loads it: each `source` in the
# calling files is wrapped in a presence test, so an absent lib file does not fail
# the load. If the helper is then called anyway, bash returns 127 and the call
# evaluates FALSE -- which at these sites means a perfectly readable ruleset is
# reported as UNKNOWN. That is a silent false negative on a firewall-verification
# path, i.e. exactly the "no false ACTIVE state" invariant these files exist to hold.
#
# So the rule is not "source the file". It is: A CALLER MUST BE ABLE TO RESOLVE THE
# PREDICATE EVEN WHEN THE LIB FILE IS ABSENT. That is satisfied by the loader pair:
# a soft source, plus a fallback definition guarded by `declare -F`.
#
# The fallback body must be BYTE-IDENTICAL to the canonical body, so the two can
# never diverge into two different predicates.
# meta:name="check-predicate-loader-authority"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:created_date="2026-09-03"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Every file that INVOKES nftban_has_non_whitespace must be able to resolve it even when lib/shell_predicates.sh is absent, via a soft source plus a declare -F fallback whose body is byte-identical to the canonical definition. Without the fallback an absent lib file returns 127, the predicate evaluates FALSE, and a readable nft ruleset is silently reported UNKNOWN on a firewall-verification path."
# meta:inventory.files="cli/lib/nftban/lib/shell_predicates.sh"
# meta:input="cli/lib/nftban/lib/shell_predicates.sh, every .sh under cli/lib/nftban and scripts that invokes the predicate"
# meta:output="PASS/FAIL per caller; SKIP (declared vacuous) when no caller exists; exit 1 on any violation"
# meta:inventory.privileges="none"

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

LIB="cli/lib/nftban/lib/shell_predicates.sh"
FAIL=0
note() { printf '  %s\n' "$*"; }

[[ -f "$LIB" ]] || { echo "FAIL: $LIB is missing — the canonical predicate is gone"; exit 1; }

# Canonical body, normalised on whitespace so formatting is not the subject.
CANON="$(sed -n '/^nftban_has_non_whitespace()/,/^}/p' "$LIB" | sed -n '2p' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
[[ -n "$CANON" ]] || { echo "FAIL: could not extract the canonical predicate body from $LIB"; exit 1; }
note "canonical body: $CANON"

# Callers = files that INVOKE the predicate. Its own definition, the loader
# fallbacks and the contract test are not callers.
# SELF-EXCLUSION BY RESOLVED PATH, not by name match. This guard necessarily
# contains the predicate's name in its own patterns; without this it would report
# ITSELF as a non-conforming caller. A checker must never be its own subject.
SELF="$(realpath "${BASH_SOURCE[0]}")"
# A CALLER INVOKES the predicate. A file that only mentions it -- in a `source`
# line, a `declare -F` guard, or a comment -- is not a caller. Requiring an
# argument-shaped invocation is what separates the two.
mapfile -t CALLERS < <(
  grep -rlnE '(^|[^#[:alnum:]_$])nftban_has_non_whitespace[[:space:]]+"' \
      --include='*.sh' cli/lib/nftban scripts 2>/dev/null \
  | grep -v '/tests/' \
  | while read -r c; do
        [[ "$(realpath "$c")" == "$SELF" ]] && continue
        [[ "$(realpath "$c")" == "$(realpath "$LIB")" ]] && continue
        printf '%s\n' "$c"
    done | sort
)

if (( ${#CALLERS[@]} == 0 )); then
  # DECLARED_SUBJECT_POPULATION=0 is vacuous, not a pass. Say so out loud.
  echo "SKIP: no caller of nftban_has_non_whitespace exists yet — guard is VACUOUS, not passing"
  exit 0
fi
note "callers: ${#CALLERS[@]}"

for f in "${CALLERS[@]}"; do
  if ! grep -q 'lib/shell_predicates\.sh' "$f"; then
    echo "FAIL: $f calls nftban_has_non_whitespace but never sources lib/shell_predicates.sh"
    FAIL=1; continue
  fi
  if ! grep -q 'declare -F nftban_has_non_whitespace' "$f"; then
    echo "FAIL: $f soft-loads the predicate with no 'declare -F' fallback."
    echo "      An absent lib file would return 127, and the call would evaluate FALSE —"
    echo "      silently reporting a readable ruleset as UNKNOWN."
    FAIL=1; continue
  fi
  # Compare the CONDITIONAL EXPRESSION, not its brace wrapper: the canonical body is
  # extracted bare from the lib file while the fallback is inline as `{ ...; }`.
  # Without this normalisation the guard rejects every conforming caller.
  body="$(grep -A1 'declare -F nftban_has_non_whitespace' "$f" | tr -s '[:space:]' ' ' \
          | grep -o '\[\[.*\]\]' | head -1 | sed 's/^ //;s/ $//')"
  if [[ "$body" != "$CANON" ]]; then
    echo "FAIL: $f fallback body diverges from the canonical predicate"
    echo "      canonical: $CANON"
    echo "      fallback : ${body:-<not found>}"
    FAIL=1; continue
  fi
  note "OK $f"
done

(( FAIL == 0 )) && echo "PASS: all ${#CALLERS[@]} caller(s) can resolve the predicate without the lib file"
exit $FAIL
