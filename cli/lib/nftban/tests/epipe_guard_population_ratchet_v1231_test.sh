#!/usr/bin/env bash
# =============================================================================
# NFTBan — v1.231.0 Lane G: EPIPE guard population + detector + ratchet
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="epipe_guard_population_ratchet_v1231_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-17"
# meta:description="Pins the v1.231.0 Lane G correction of check-pipefail-epipe-shortcircuit.sh. Before it, the union of the guard's two populations was 428 files containing ZERO product code: the guard governed the control plane and the product's TESTS, never the product, while a read-only census found 74 SIGPIPE-sensitive sites under cli/, 39 of them on a security- or count-reporting surface. Two independent defects are pinned. POPULATION: product_population() is derived from the packaging manifest and systemd ExecStart targets and must contain named product files the census proved were excluded; an EMPTY product plane must FAIL LOUDLY rather than pass vacuously. DETECTOR: the builtin-producer exemption was MEASURED FALSE (echo of a 202,399-byte variable into grep -q returns 141, 20/20) so a builtin producer must now be flagged, and `head` — 19 of the 74 sensitive sites — must be recognised as a short-circuiting consumer. RATCHET: all three directions are proven BY INJECTION into an isolated fixture — a new undeclared site, a declared site that disappears, and a registry row nothing consumes. Also asserts no false positive on read-to-EOF consumers. Hermetic: builds its own fixture tree, never touches the repo."
# meta:input="None (fixture tree under mktemp -d; repo files are read only)"
# meta:output="PASS/FAIL/NOT_EXECUTED per arm; exit 0 only when every arm PASSed"
# meta:depends="bash,git,grep,sed,awk,sha256sum"
# meta:inventory.files="scripts/ci/check-pipefail-epipe-shortcircuit.sh,scripts/ci/gen-pipefail-epipe-inventory.sh,scripts/ci/data/pipefail-epipe-exposure-registry.tsv,scripts/ci/data/pipefail-epipe-test-corpus-inventory.tsv,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,git,grep,sed,awk,sha256sum"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="epipe_guard_population_ratchet_v1231_test"
# meta:ta.owner="architecture"
# meta:ta.module="epipe-shortcircuit"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
# ⛔ THE FORBIDDEN SHAPE IS ASSEMBLED, NEVER WRITTEN LITERALLY. A `producer |
#    short-circuit-consumer` pipeline written literally in this file would be a
#    real site in a real merge-deciding test, and the guard would flag its own
#    fixtures. It is built from $BAR at runtime, as data. This file's own code
#    uses here-strings, single processes and read-to-EOF consumers only.
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/check-pipefail-epipe-shortcircuit.sh"
GEN="$REPO_ROOT/scripts/ci/gen-pipefail-epipe-inventory.sh"

PASS=0; FAIL=0; SKIP=0
pass(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
# NOT_EXECUTED is its own verdict class. A precondition that did not hold is not
# a pass and not a failure — recording it as either would be a false statement
# about what was measured.
skip(){ printf '  [NOT_EXECUTED] %s — %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

BAR='|'
GQ='grep -q'
HEAD1='head -1'

echo "=== v1.231.0 Lane G — EPIPE guard population, detector, ratchet ==="

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
PRE_OK=1
for _b in git grep sed awk sha256sum; do
    command -v "$_b" >/dev/null 2>&1 || { PRE_OK=0; MISSING="$_b"; }
done
[[ -f "$GUARD" ]] || { PRE_OK=0; MISSING="${MISSING:-$GUARD}"; }
[[ -f "$GEN" ]] || { PRE_OK=0; MISSING="${MISSING:-$GEN}"; }

# -----------------------------------------------------------------------------
# GROUP A — POPULATION: the product execution plane is actually scanned
# -----------------------------------------------------------------------------
# Sourcing the guard in lib-only mode gives us the REAL population functions, so
# this arm measures the shipped guard rather than a re-implementation of it.
# It arms errexit in this shell, so every subsequent status is captured
# explicitly rather than relied upon.
echo "-- A. population"
if [[ "$PRE_OK" -ne 1 ]]; then
    skip "A1 named product files are in the scanned population" "missing ${MISSING:-precondition}"
    skip "A2 an empty product plane fails loudly" "missing ${MISSING:-precondition}"
else
    POP=""
    POP_RC=0
    POP="$( cd "$REPO_ROOT" && EPIPE_GUARD_LIB_ONLY=1 bash -c '
        . scripts/ci/check-pipefail-epipe-shortcircuit.sh
        product_population
    ' )" || POP_RC=$?

    if [[ "$POP_RC" -ne 0 || -z "$POP" ]]; then
        skip "A1 named product files are in the scanned population" "product_population() did not execute (rc=$POP_RC)"
    else
        # Each of these was proven ABSENT from the guard's population at
        # origin/main 4654bb21: the union of gate_population() and
        # test_corpus_population() was 428 files with zero under cli/sbin or
        # cli/lib/nftban/{cli,core,lib,setup,helpers,cron,exporters,health}.
        _missing=""
        for _f in \
            cli/sbin/nftban \
            cli/sbin/nftban-botscan-processor \
            cli/lib/nftban/cli/cmd_botguard.sh \
            cli/lib/nftban/cli/cmd_status.sh \
            cli/lib/nftban/core/nftban_firewall_conflicts.sh \
            cli/lib/nftban/core/nftban_ddos_classic.sh \
            cli/lib/nftban/lib/ssh_port_detect.sh \
            cli/lib/nftban/lib/nft_schema.sh \
            cli/lib/nftban/cron/maintenance.sh \
            cli/lib/nftban/core/nftban_health_checks_security.sh
        do
            grep -qxF "$_f" <<< "$POP" || _missing="${_missing:+$_missing }$_f"
        done
        _n=0; _n="$(grep -c '' <<< "$POP")" || _n=0
        if [[ -z "$_missing" ]]; then
            pass "A1 product plane scanned ($_n files) and contains every named census-excluded file"
        else
            fail "A1 still outside the population: $_missing"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Fixture — an isolated tree with its own packaging manifest, product files and
# registry. Built from scratch so no arm can be satisfied by the real repo.
# -----------------------------------------------------------------------------
FIX=""
FIX_OK=0
if [[ "$PRE_OK" -eq 1 ]]; then
    FIX="$(mktemp -d)"
    trap 'rm -rf "$FIX"' EXIT
    mkdir -p "$FIX/scripts/ci/data" "$FIX/packaging" "$FIX/install/systemd" \
             "$FIX/cli/sbin" "$FIX/cli/lib/nftban/cli" "$FIX/cli/lib/nftban/core" \
             "$FIX/cli/lib/nftban/tests" "$FIX/.github/workflows"

    cp "$GUARD" "$FIX/scripts/ci/check-pipefail-epipe-shortcircuit.sh"
    cp "$GEN"   "$FIX/scripts/ci/gen-pipefail-epipe-inventory.sh"

    # Packaging manifest stub — only the %files payload lines matter; they are
    # the authority product_population() derives the subtrees from.
    {
        printf '#!/usr/bin/env bash\n# fixture packaging manifest\n'
        printf '/usr/lib/nftban/bin/*\n'
        printf '/usr/lib/nftban/sbin/*\n'
        printf '/usr/lib/nftban/cli/*\n'
        printf '/usr/lib/nftban/core/*\n'
        printf '/usr/lib/nftban/tests/*\n'
    } > "$FIX/packaging/build_nftban.sh"

    printf '[Service]\nExecStart=/usr/lib/nftban/sbin/nftban-fixture-helper\n' \
        > "$FIX/install/systemd/nftban-fixture.service"

    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\ntrue\n' > "$FIX/cli/sbin/nftban"
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\ntrue\n' > "$FIX/cli/sbin/nftban-fixture-helper"

    # The BUILTIN-PRODUCER site, in the exact shape of cmd_botguard.sh:180 —
    # `if ! echo "$output" | grep -q 'elements = {'`. Negated, so an EPIPE is a
    # DETERMINISTIC wrong answer rather than a flaky one: 141 inverts to true and
    # a populated set reports zero elements every time.
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf '_count() {\n    local output\n    output="$(nft list set ip nftban bl_v4 2>/dev/null)" || { echo 0; return; }\n'
        printf '    if ! echo "$output" %s %s "elements = {"; then echo 0; return; fi\n' "$BAR" "$GQ"
        printf '    echo 1\n}\n'
    } > "$FIX/cli/lib/nftban/cli/cmd_fixture_builtin.sh"

    # The HEAD consumer site. `head` stops after the requested amount, so the
    # producer takes SIGPIPE with the CORRECT value already on stdout — the
    # answer is right and the status is wrong, which is the whole hazard.
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf '_oldest() {\n    local f\n    f="$(find /var/lib/nftban -type f -printf "%%T@ %%p\\n" 2>/dev/null %s sort -n %s %s)"\n' "$BAR" "$BAR" "$HEAD1"
        printf '    printf "%%s" "$f"\n}\n'
    } > "$FIX/cli/lib/nftban/core/nftban_fixture_head.sh"

    # A genuinely SAFE file: read-to-EOF consumers and a grep that reads a FILE.
    # If this is ever flagged the guard has stopped distinguishing the shape it
    # bans from ordinary shell, and every arm above becomes noise.
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf '_safe() {\n'
        printf '    local n\n'
        printf '    n="$(nft list ruleset 2>/dev/null %s wc -l)" || n=0\n' "$BAR"
        printf '    grep -qF nftban /etc/nftban/nftban.conf || true\n'
        printf '    [ -z "$n" ] || grep -qF x /etc/hostname || true\n'
        printf '    nft list ruleset 2>/dev/null %s sort -u %s tail -5 >/dev/null || true\n' "$BAR" "$BAR"
        printf '    printf "%%s" "$n"\n}\n'
    } > "$FIX/cli/lib/nftban/core/nftban_fixture_safe.sh"

    # The declared-exclusion coverage assertion (A5 in the guard) needs the test
    # subtree to be owned by the executed-test corpus.
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\ntrue\n' > "$FIX/cli/lib/nftban/tests/fixture_test.sh"
    printf 'fixture_test\tcli/lib/nftban/tests/fixture_test.sh\tcli\ttest\tfixture\tCI_HERMETIC_SHELL\tci-bash\ttrue\tfalse\tfalse\tfalse\tfalse\tfalse\n' \
        > "$FIX/scripts/ci/test-authority-index.tsv"

    # EMPTY baselines, not absent ones. An absent registry makes the guard report
    # EPIPE_REGISTRY_MISSING and stop before it names any site, which would make
    # the detector arms below pass or fail for the wrong reason. Empty means
    # "nothing is declared yet", so every detected site must surface by name.
    printf '# fixture registry — intentionally empty\n' \
        > "$FIX/scripts/ci/data/pipefail-epipe-exposure-registry.tsv"
    printf '# fixture inventory — intentionally empty\n' \
        > "$FIX/scripts/ci/data/pipefail-epipe-test-corpus-inventory.tsv"

    (
        cd "$FIX" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email fixture@example.invalid >/dev/null 2>&1
        git config user.name fixture >/dev/null 2>&1
        git add -A >/dev/null 2>&1
    ) && FIX_OK=1
fi

run_guard_in_fixture() {
    local out rc=0
    out="$( cd "$FIX" && bash scripts/ci/check-pipefail-epipe-shortcircuit.sh 2>&1 )" || rc=$?
    printf '%s\n' "$out"
    return "$rc"
}
regen_in_fixture() {
    ( cd "$FIX" && bash scripts/ci/gen-pipefail-epipe-inventory.sh >/dev/null 2>&1 )
}

# -----------------------------------------------------------------------------
# GROUP B — DETECTOR: the two corrections, proven on the fixture
# -----------------------------------------------------------------------------
echo "-- B. detector"
BASE_OUT=""
if [[ "$FIX_OK" -ne 1 ]]; then
    skip "B1 a BUILTIN producer is detected" "fixture tree was not built"
    skip "B2 a head consumer is detected" "fixture tree was not built"
    skip "B3 no false positive on read-to-EOF consumers" "fixture tree was not built"
else
    # No registry yet: every fixture site must surface as UNDECLARED. That is
    # also the cheapest possible proof that the sites are SEEN at all.
    BASE_OUT="$(run_guard_in_fixture)" || true

    if [[ "$BASE_OUT" == *"cmd_fixture_builtin.sh"* ]]; then
        pass "B1 a BUILTIN producer (echo \"\$output\" into grep -q) IS detected"
    else
        fail "B1 the builtin-producer exemption is back — 21 measured product sites go invisible"
    fi

    if [[ "$BASE_OUT" == *"nftban_fixture_head.sh"* ]]; then
        pass "B2 a 'head' consumer IS detected (19 of the census's 74 sensitive sites)"
    else
        fail "B2 'head' is still unrecognised as a short-circuiting consumer"
    fi

    if [[ "$BASE_OUT" == *"nftban_fixture_safe.sh"* ]]; then
        fail "B3 FALSE POSITIVE: wc/sort/tail and a file-reading grep were flagged"
    else
        pass "B3 no false positive: read-to-EOF consumers and '||' are not flagged"
    fi
fi

# -----------------------------------------------------------------------------
# GROUP C — POPULATION ASSERTION: empty must fail LOUDLY
# -----------------------------------------------------------------------------
echo "-- C. population assertion"
# ⛔ Each arm matches the assertion's OWN failure token, never a prefix of the
# counter line. `EPIPE_PRODUCT_POPULATION` is a substring of
# `PIPEFAIL_EPIPE_PRODUCT_POPULATION_FAILURES = 0`, so matching it would have
# passed on a GREEN run — this arm read as proven while proving nothing until the
# token was tightened. A control that can pass while the subject is clean is not
# a control.
if [[ "$FIX_OK" -ne 1 ]]; then
    skip "C1 an empty product plane FAILS" "fixture tree was not built"
    skip "C2 an uncovered declared exclusion FAILS" "fixture tree was not built"
    skip "C3 an entrypoint that drops pipefail FAILS" "fixture tree was not built"
else
    # C1 — every authority for the plane removed at once: no packaging manifest,
    # no cli/sbin, no units. The derived population collapses to nothing. A guard
    # that went green here would be green because it inspects nothing — the exact
    # failure mode of the three previous population corrections, each of which
    # had to be found by hand instead of being reported.
    mv "$FIX/packaging/build_nftban.sh" "$FIX/away-manifest"
    mv "$FIX/cli/sbin" "$FIX/away-sbin"
    mv "$FIX/install/systemd" "$FIX/away-units"
    _o="$(run_guard_in_fixture)" || true
    mv "$FIX/away-manifest" "$FIX/packaging/build_nftban.sh"
    mv "$FIX/away-sbin" "$FIX/cli/sbin"
    mv "$FIX/away-units" "$FIX/install/systemd"
    if [[ "$_o" == *"EPIPE_PRODUCT_POPULATION_EMPTY"* ]]; then
        pass "C1 a collapsed product population FAILS loudly instead of passing vacuously"
    else
        fail "C1 the product population can silently shrink to nothing"
    fi

    # C2 — cli/lib/nftban/tests is kept out of the product plane ONLY because the
    # executed-test corpus owns it. Take that away and the exclusion becomes a
    # hole; the guard must say so rather than keep excluding.
    cp "$FIX/scripts/ci/test-authority-index.tsv" "$FIX/.idx.bak"
    : > "$FIX/scripts/ci/test-authority-index.tsv"
    _o="$(run_guard_in_fixture)" || true
    cp "$FIX/.idx.bak" "$FIX/scripts/ci/test-authority-index.tsv"
    if [[ "$_o" == *"EPIPE_EXCLUSION_UNCOVERED"* ]]; then
        pass "C2 a declared exclusion nothing else covers FAILS"
    else
        fail "C2 the tests exclusion can become an unscanned hole silently"
    fi

    # C3 — the product plane is scanned without a per-file pipefail precondition
    # because sourced libraries inherit it from the entrypoints. That premise is
    # asserted, not assumed: drop pipefail from an entrypoint and the guard must
    # report that the premise no longer holds.
    cp "$FIX/cli/sbin/nftban" "$FIX/.entry.bak"
    printf '#!/usr/bin/env bash\nset -eu\ntrue\n' > "$FIX/cli/sbin/nftban"
    _o="$(run_guard_in_fixture)" || true
    cp "$FIX/.entry.bak" "$FIX/cli/sbin/nftban"
    if [[ "$_o" == *"EPIPE_PIPEFAIL_PREMISE"* ]]; then
        pass "C3 an entrypoint that drops pipefail FAILS (the inherited-pipefail premise is asserted)"
    else
        fail "C3 the inherited-pipefail premise is assumed, not asserted"
    fi
fi

# -----------------------------------------------------------------------------
# GROUP D — RATCHET, three directions, each BY INJECTION
# -----------------------------------------------------------------------------
# Inspecting a ratchet does not show that it ratchets. Each direction is caused,
# then observed, then reverted.
echo "-- D. ratchet (injection)"
D_READY=0
if [[ "$FIX_OK" -eq 1 ]] && regen_in_fixture; then
    _ctl="$(run_guard_in_fixture)" && D_READY=1 || D_READY=0
    if [[ "$D_READY" -ne 1 ]]; then
        skip "D control: the seeded fixture is clean" "guard is red on the freshly generated baseline"
        printf '%s\n' "$_ctl" > "$FIX/.control.log"
    else
        pass "D0 control: the fixture is clean once its registry is generated"
    fi
else
    skip "D control: the seeded fixture is clean" "fixture or generator did not run"
fi

if [[ "$D_READY" -ne 1 ]]; then
    skip "D1 a NEW undeclared site FAILS" "control arm did not establish a clean baseline"
    skip "D2 a declared site that DISAPPEARS FAILS" "control arm did not establish a clean baseline"
    skip "D3 a registry row nothing consumes FAILS" "control arm did not establish a clean baseline"
else
    _victim="$FIX/cli/lib/nftban/cli/cmd_fixture_builtin.sh"
    _reg="$FIX/scripts/ci/data/pipefail-epipe-exposure-registry.tsv"

    # D1 — a NEW exposed site that nobody declared.
    cp "$_victim" "$FIX/.victim.bak"
    printf '_extra() { if systemctl list-units --all %s %s nftban; then true; fi; }\n' "$BAR" "$GQ" >> "$_victim"
    _o="$(run_guard_in_fixture)" || true
    cp "$FIX/.victim.bak" "$_victim"
    if [[ "$_o" == *"EPIPE_UNDECLARED"* && "$_o" == *"cmd_fixture_builtin.sh"* ]]; then
        pass "D1 a NEW undeclared exposed site FAILS"
    else
        fail "D1 new exposure is accepted silently — the ratchet does not ratchet up"
    fi

    # D2 — a DECLARED site that disappears without reconciliation. Deleting the
    # site is what a real fix looks like; the registry must be reconciled with
    # it, or a disappearance is unexplainable and the debt silently re-accumulates.
    cp "$_victim" "$FIX/.victim.bak"
    _fixed="$(sed "s@${BAR}[[:space:]]*grep -q@${BAR} grep -c@" "$_victim")"
    printf '%s\n' "$_fixed" > "$_victim"
    _o="$(run_guard_in_fixture)" || true
    cp "$FIX/.victim.bak" "$_victim"
    if [[ "$_o" == *"EPIPE_REGISTRY_STALE"* && "$_o" == *"cmd_fixture_builtin.sh"* ]]; then
        pass "D2 a declared site that DISAPPEARS without reconciliation FAILS"
    else
        fail "D2 declared exposure can vanish unrecorded — silent drift is accepted"
    fi

    # D3 — a registry row nothing consumes. The file is not in any population, so
    # the row can never constrain anything again; a registry that keeps such rows
    # rots into decoration.
    cp "$_reg" "$FIX/.reg.bak"
    printf 'product\tcli/lib/nftban/core/nftban_fixture_deleted.sh\t0123456789abcdef\t1\tgrep-q\tA\tinjected rotting row\n' >> "$_reg"
    _o="$(run_guard_in_fixture)" || true
    cp "$FIX/.reg.bak" "$_reg"
    if [[ "$_o" == *"EPIPE_REGISTRY_ORPHAN"* && "$_o" == *"nftban_fixture_deleted.sh"* ]]; then
        pass "D3 a registry row that no site consumes FAILS"
    else
        fail "D3 the registry may rot — rows can outlive the population they describe"
    fi
fi

# -----------------------------------------------------------------------------
echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$SKIP ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
if [[ "$SKIP" -gt 0 ]]; then
    # A skipped arm is not a passed arm. An unmeasured control cannot clear the
    # subject, so an incomplete run is reported as a failure of the RUN, not as
    # a verdict on the guard.
    echo "RESULT: NOT_EXECUTED ($SKIP arm(s) had unmet preconditions) — no verdict"
    exit 1
fi
echo "RESULT: PASS"
exit 0
