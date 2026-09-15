#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — guard-the-guard for check-pipefail-epipe-shortcircuit.sh
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:description="Proves the v1.231.0 POPULATION CORRECTION, not merely that unsafe
#   syntax is detectable. The EPIPE guard was correct in RULE and wrong in SUBJECT: it
#   scoped by the filename pattern scripts/ci/check-*.sh, so migration-coverage-gate.sh —
#   which has its own blocking workflow and carried the forbidden form in the FAIL-OPEN
#   direction — was never scanned. The decisive arm therefore uses a fixture whose name
#   does NOT match check-*.sh but which IS wired as merge-deciding: the guard must fail on
#   it. Also pins the two matcher corrections the wider population exposed (indented
#   comments are MENTION not CODE; `||` is not a pipe) and the builtin-producer exemption,
#   because narrowing a matcher is how a guard gets quietly disarmed."
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILS=0
ok(){ printf '  [PASS] %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "=== guard-the-guard: pipefail/EPIPE population + matcher ==="


# ⛔ The forbidden form is ASSEMBLED, never written literally. A falsifier must carry
# the defect as DATA, not as source text: written literally, the guard flags its own
# fixtures, and excluding the falsifier would re-open the population hole this change
# exists to close. Evidence apparatus is part of the subject (merge-train rule 7).
BAR='|'; GQ='grep -q'; GQFX='grep -qFx'
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
# v1.231.0 D4: the corpus arms need the executed test files themselves, or the
# inventory check sees 66 "recorded but missing" files and every arm is noise.
mkdir -p "$D/cli/lib/nftban"
cp -a "$ROOT/.github" "$ROOT/scripts" "$D/" 2>/dev/null
cp -a "$ROOT/cli/lib/nftban/tests" "$D/cli/lib/nftban/" 2>/dev/null
cd "$D"; git init -q . 2>/dev/null; git add -A >/dev/null 2>&1

run_guard(){ ( cd "$D" && bash scripts/ci/check-pipefail-epipe-shortcircuit.sh 2>&1 ) || true; }

# --- control: the tree as-shipped must be clean, or every arm below is noise ---
_out="$(run_guard)"
if [[ "$_out" == *"SITES = 0"* && "$_out" == *"DEVIATIONS = 0"* ]]; then
    ok "0 control: the shipped tree is clean (arms below are meaningful)"
else
    bad "0 control: the shipped tree already fails — cannot attribute the arms"
    printf '%s\n' "$_out" | grep FAIL | head -3 | sed 's/^/        /' || true
fi

# --- THE DECISIVE ARM: out-of-prefix, CI-wired, unsafe --------------------------
# Name deliberately does NOT match check-*.sh. Wired into a workflow, so the
# DERIVED population must include it. Under the OLD filename-pattern scope this
# file was invisible and the guard reported success.
{ printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
  printf 'if find . -name "*.go" %s %s .; then\n    echo "violation found"\nfi\n' "$BAR" "$GQ"
} > scripts/ci/somegate-not-check-prefixed.sh
mkdir -p .github/workflows
printf 'name: x\non: [push]\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash scripts/ci/somegate-not-check-prefixed.sh\n' \
    > .github/workflows/zz-falsifier-gate.yml
git add -A >/dev/null 2>&1
out="$(run_guard)"
if [[ "$out" == *"somegate-not-check-prefixed"* ]]; then
    ok "1 POPULATION: an out-of-prefix, CI-WIRED gate IS scanned and fails"
else
    bad "1 POPULATION NOT CORRECTED — the exact defect class is still invisible"
    printf '%s\n' "$out" | tail -3 | sed 's/^/        /'
fi
rm -f scripts/ci/somegate-not-check-prefixed.sh .github/workflows/zz-falsifier-gate.yml
git add -A >/dev/null 2>&1

# --- matcher corrections, each pinned so it cannot silently regress -------------
{ printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
  printf '    # deliberately mentions find . %s %s . inside an INDENTED comment\ntrue\n' "$BAR" "$GQ"
} > scripts/ci/check-zz-indented-comment.sh
git add -A >/dev/null 2>&1
_o="$(run_guard)"
if [[ "$_o" == *"check-zz-indented-comment"* ]]; then bad "2 an INDENTED comment is matched as code (MENTION != CODE)"; else ok "2 an indented comment describing the form is NOT matched"; fi
rm -f scripts/ci/check-zz-indented-comment.sh; git add -A >/dev/null 2>&1

cat > scripts/ci/check-zz-oroperator.sh <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
pat=x; cap=/dev/null
[ -z "$pat" ] || grep -qF -- "$pat" "$cap" 2>/dev/null || true
EOS
git add -A >/dev/null 2>&1
_o="$(run_guard)"
if [[ "$_o" == *"check-zz-oroperator"* ]]; then bad "3 the OR operator '||' is matched as a pipe"; else ok "3 '||' is not treated as a pipe (grep reads a FILE here)"; fi
rm -f scripts/ci/check-zz-oroperator.sh; git add -A >/dev/null 2>&1

{ printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nh="a b c"\n'
  printf 'if echo "$h" %s %s "b"; then true; fi\n' "$BAR" "$GQFX"
} > scripts/ci/check-zz-builtin.sh
git add -A >/dev/null 2>&1
_o="$(run_guard)"
if [[ "$_o" == *"check-zz-builtin"* ]]; then bad "4 a BUILTIN producer was flagged (cannot EPIPE in practice)"; else ok "4 builtin producer exempt by mechanism"; fi
rm -f scripts/ci/check-zz-builtin.sh; git add -A >/dev/null 2>&1

# --- NOT BLINDED: the original motivating form must STILL fail ------------------
{ printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
  printf 'if nft list ruleset 2>/dev/null %s %s nftban; then true; fi\n' "$BAR" "$GQ"
} > scripts/ci/check-zz-realpipe.sh
git add -A >/dev/null 2>&1
_o="$(run_guard)"
if [[ "$_o" == *"check-zz-realpipe"* ]]; then
    ok "5 NOT BLINDED: a real streaming producer piped to grep -q still FAILS"
else
    bad "5 the matcher corrections BLINDED the guard to the original defect"
fi
rm -f scripts/ci/check-zz-realpipe.sh

# --- D4 ARMS: the executed-test corpus is a real population, not decoration ----
# A test whose verdict is merge evidence is a merge-deciding subject. These arms
# fail if the corpus is scanned vacuously or the ratchet can be walked past.
IDX="scripts/ci/test-authority-index.tsv"
INV="scripts/ci/data/pipefail-epipe-test-corpus-inventory.tsv"

# 6: a NEW indexed test, outside scripts/ci/, carrying the forbidden shape.
#    This is the exact shape that hid four real product defects in
#    v131_pr_a_2_double_zero_sweep_test. It MUST be caught.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'if cat /etc/hostname %s %s x; then true; fi\n' "$BAR" "$GQ"
} > cli/lib/nftban/tests/zz_falsifier_corpus_test.sh
printf 'zz_falsifier_corpus_test\tcli/lib/nftban/tests/zz_falsifier_corpus_test.sh\tx\ttest\tx\tCI_HERMETIC_SHELL\tci-bash\ttrue\tfalse\tfalse\tfalse\tfalse\tfalse\n' >> "$IDX"
git add -A >/dev/null 2>&1
_o="$(run_guard)"
if [[ "$_o" == *"EPIPE_UNDECLARED"* && "$_o" == *"zz_falsifier_corpus_test"* ]]; then
    ok "6 CORPUS: a new BLOCKING test outside scripts/ci/ with the forbidden shape FAILS"
else
    bad "6 CORPUS HOLE: a merge-deciding shell test can carry the inverted shape unseen"
fi
git checkout -- "$IDX" 2>/dev/null || sed -i '/zz_falsifier_corpus_test/d' "$IDX"
rm -f cli/lib/nftban/tests/zz_falsifier_corpus_test.sh

# 7: adding a site to an ALREADY-INVENTORIED file must fail (new debt).
_victim="$(awk -F'\t' '!/^#/{print $1; exit}' "$INV")"
if [[ -n "$_victim" && -f "$_victim" ]]; then
    cp "$_victim" "$D/.victim.bak"
    printf 'if cat /etc/hostname %s %s zzz; then true; fi\n' "$BAR" "$GQ" >> "$_victim"
    git add -A >/dev/null 2>&1
    _o="$(run_guard)"
    if [[ "$_o" == *"EPIPE_NEW_DEBT"* ]]; then
        ok "7 RATCHET: adding a site to an inventoried file FAILS"
    else
        bad "7 RATCHET BROKEN: new timing-dependent debt is accepted silently"
    fi
    cp "$D/.victim.bak" "$_victim"
else
    bad "7 RATCHET: inventory is empty — nothing to ratchet against"
fi

# 8: REMOVING a site without regenerating must also fail — otherwise the debt
#    silently re-accumulates after someone improves a file.
if [[ -n "$_victim" && -f "$_victim" ]]; then
    cp "$_victim" "$D/.victim.bak"
    sed -i "s@${BAR}[[:space:]]*grep -q@| grep -c@" "$_victim"
    git add -A >/dev/null 2>&1
    _o="$(run_guard)"
    if [[ "$_o" == *"EPIPE_INVENTORY_STALE"* ]]; then
        ok "8 RATCHET: an unrecorded improvement FAILS (gain must be locked in)"
    else
        bad "8 RATCHET: counts may drift downward unrecorded — debt can re-accumulate"
    fi
    cp "$D/.victim.bak" "$_victim"
fi

# --- D4b ARMS: PATH DEPTH must not decide whether a gate is inspected -----------
# The population regex previously forbade '/', so four workflow-invoked scripts one
# directory down were never scanned. Depth is not a property that should determine
# whether a merge-deciding gate is checked.

# 9: a NESTED, workflow-invoked script carrying the forbidden shape must be caught.
mkdir -p scripts/ci/tests
{ printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
  printf 'if find . -name "*.c" %s %s .; then echo hit; fi\n' "$BAR" "$GQ"
} > scripts/ci/tests/zz-nested-falsifier.sh
printf 'name: y\non: [push]\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash scripts/ci/tests/zz-nested-falsifier.sh\n' \
    > .github/workflows/zz-nested-falsifier.yml
git add -A >/dev/null 2>&1
_o="$(run_guard)"
if [[ "$_o" == *"zz-nested-falsifier"* ]]; then
    ok "9 DEPTH: a NESTED workflow-invoked gate IS scanned and fails"
else
    bad "9 DEPTH HOLE: scripts below scripts/ci/ are still invisible to the guard"
fi

# 10: the depth-exclusion assertion must report the nested file as IN population
#     (it is the assertion that converts "my regex is fine" into a proof).
if [[ "$_o" == *"DEPTH_EXCLUSIONS = 0"* ]]; then
    ok "10 DEPTH ASSERTION: nested workflow-invoked script counted as in-population"
else
    bad "10 DEPTH ASSERTION did not account for the nested script"
fi
rm -f scripts/ci/tests/zz-nested-falsifier.sh .github/workflows/zz-nested-falsifier.yml
git add -A >/dev/null 2>&1

echo "=== guard-the-guard: FAILS=$FAILS ==="
[ "$FAILS" -eq 0 ]
