#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — SHELL TEST-COUNT FLOOR  (v1.229.4 P1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-test-count-floor"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Fails when the shell test population drops below a hand-maintained floor, closing the delete-then-regenerate hole the generated index cannot close itself. Also asserts index/disk parity so the two count domains stay comparable. The floor is never generated — deriving it from the index it constrains would make the control tautological."
# meta:inventory.files="scripts/ci/data/test-count-floor.tsv,scripts/ci/test-authority-index.tsv"
# meta:inventory.privileges="none"
# =============================================================================
#
#   THE HOLE THIS CLOSES
#       delete a test               -> test-authority.py check FAILS
#       delete a test + regenerate  -> index tracks the smaller reality, SILENTLY
#   Regeneration is routine, so the index describes what IS; it cannot constrain
#   whether what IS may shrink.
#
#   ⛔ THE FLOOR MUST NOT DERIVE FROM THE INDEX IT CONSTRAINS.
#      delete -> regenerate index -> regenerate floor -> green  =  tautology.
#      The floor lives in a hand-maintained file and is read, never computed.
#
#   ⛔ COUNT MISMATCH != MISSING TEST.
#      The index carries a TSV HEADER row that is not comment-prefixed. Counting
#      non-comment lines yields data+1 and looks like an off-by-one defect. The two
#      domains are made explicitly comparable before either is judged.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLOOR_FILE="$ROOT/scripts/ci/data/test-count-floor.tsv"
INDEX="$ROOT/scripts/ci/test-authority-index.tsv"
TESTS_DIR="$ROOT/cli/lib/nftban/tests"
RC=0
ok(){ echo "  [PASS] $1"; }
no(){ echo "  [FAIL] $1"; RC=1; }

echo "=== shell test-count floor (v1.229.4 P1) ==="
for f in "$FLOOR_FILE" "$INDEX"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; exit 1; }
done

# ---- the floor: READ, never computed ----------------------------------------
FLOOR="$(awk -F'\t' '$1=="floor"{print $2; exit}' "$FLOOR_FILE" | tr -d '[:space:]')"
if ! [[ "$FLOOR" =~ ^[0-9]+$ ]]; then
    no "floor value is missing or non-numeric in $(basename "$FLOOR_FILE") — cannot constrain anything"
    echo "RESULT: FAIL"; exit 1
fi
JUST="$(awk -F'\t' '$1=="justification"{print $2; exit}' "$FLOOR_FILE")"
[[ -n "$JUST" ]] && ok "floor carries a justification" \
                 || no "floor has no justification — a bare number is not a decision"

# ---- domain A: tests on disk (independent of the index) ---------------------
DISK=$(find "$TESTS_DIR" -maxdepth 1 -name '*_test.sh' -type f 2>/dev/null | wc -l)

# ---- domain B: index DATA rows (header and comments excluded) ---------------
# The header is identified positively by its first field, not by position.
IDX=$(awk -F'\t' '!/^#/ && $1!="id" && NF>1' "$INDEX" | wc -l)

echo "    floor=$FLOOR  disk=$DISK  index_data_rows=$IDX"

if [[ "$DISK" -eq 0 || "$IDX" -eq 0 ]]; then
    no "PARSE_INCOMPLETE: a zero population is not a pass"
    echo "RESULT: FAIL"; exit 1
fi

# ---- R1 · the floor ----------------------------------------------------------
if [[ "$DISK" -ge "$FLOOR" ]]; then
    ok "test population $DISK >= floor $FLOOR"
else
    no "test population DROPPED: $DISK < floor $FLOOR"
    echo "        -> $(( FLOOR - DISK )) test(s) disappeared without the floor being lowered."
    echo "        -> If the removal is intended, LOWER the floor in $(basename "$FLOOR_FILE")"
    echo "           and say why. Regenerating the index does NOT satisfy this check."
fi

# ---- R2 · the two domains stay comparable ------------------------------------
if [[ "$DISK" -eq "$IDX" ]]; then
    ok "index data rows == tests on disk ($IDX) — domains comparable"
else
    no "index/disk divergence: $IDX indexed vs $DISK on disk"
    echo "        -> ⛔ COUNT MISMATCH != MISSING TEST. Classify the delta before acting:"
    awk -F'\t' '!/^#/ && $1!="id" && NF>1 {print $2}' "$INDEX" | sort > /tmp/.tcf_idx.$$
    find "$TESTS_DIR" -maxdepth 1 -name '*_test.sh' -type f -printf 'cli/lib/nftban/tests/%f\n' | sort > /tmp/.tcf_disk.$$
    echo "        indexed but absent from disk:"; comm -23 /tmp/.tcf_idx.$$ /tmp/.tcf_disk.$$ | sed 's/^/          /' | head -5
    echo "        on disk but not indexed:";      comm -13 /tmp/.tcf_idx.$$ /tmp/.tcf_disk.$$ | sed 's/^/          /' | head -5
    rm -f /tmp/.tcf_idx.$$ /tmp/.tcf_disk.$$
fi

# ---- R3 · the floor must not be generated ------------------------------------
# If the generator ever learns to write this file, the control becomes tautological.
if grep -q 'test-count-floor' "$ROOT/scripts/ci/test-authority.py" 2>/dev/null; then
    no "test-authority.py references the floor file — the floor must NOT be generated by the index authority"
else
    ok "the floor is independent of the index generator (not tautological)"
fi

echo
[[ $RC -eq 0 ]] && echo "RESULT: test-count floor PASS" || echo "RESULT: test-count floor FAIL"
exit $RC
