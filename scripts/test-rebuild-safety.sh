#!/usr/bin/env bash
# =============================================================================
# NFTBan CI Gate G18: Rebuild / Convergence Safety
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# Purpose: Assert the rebuild/convergence invariants of the Layer-0 authority.
#
# meta:name="test-rebuild-safety"
# meta:type="ci"
# meta:version="1.229.7"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-08"
# meta:inventory.files="scripts/test-rebuild-safety.sh,install/nftables/nftables.conf.tpl,cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/lib/nft_fragment.sh,cli/lib/nftban/core/nftban_ddos_classic.sh,cmd/nftban-installer/phases.go,internal/installer/switchop/rebuild.go"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# -----------------------------------------------------------------------------
# v1.229.7 REPAIR — the previous implementation was TEST_INVALID for TWO
# INDEPENDENT REASONS, and was BLOCKING while unable to fail:
#
#   1. VIOLATIONS was initialised and NEVER incremented. Every finding emitted
#      ::warning::, which does not fail a job. The failure branch was dead.
#   2. All FIVE declared subject files did not exist. Every check was wrapped in
#      `if [[ -f "$file" ]]`, so a missing subject SILENTLY SKIPPED. The guard
#      never opened the file that actually performs the rebuild.
#
#   CURRENT GREEN != COVERAGE          SUBJECT_NOT_FOUND = TEST FAILURE
#   ENOENT != ABSENCE                  REPAIR EXISTING GUARD != START NEW AUDIT
#
# Bounded STRICTLY to the rebuild/convergence property. There is deliberately
# NO fallback to broader repository scanning when a subject is missing — that
# is the defect this repair exists to remove.
# =============================================================================

set -Eeuo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

VIOLATIONS=0

violation() {
    VIOLATIONS=$((VIOLATIONS + 1))          # <-- the accumulator IS connected
    echo "::error title=G18 rebuild-safety::$1"
}
pass() { echo "   PASS  $1"; }

# --- declared subjects: the files that ACTUALLY implement rebuild/convergence --
# Verified present at v1.229.6. If one moves, this guard FAILS rather than skips.
SUBJECTS=(
    "install/nftables/nftables.conf.tpl"
    "cli/lib/nftban/cli/cmd_firewall.sh"
    "cli/lib/nftban/lib/nft_fragment.sh"
    "cli/lib/nftban/core/nftban_ddos_classic.sh"
    "cmd/nftban-installer/phases.go"
    "internal/installer/switchop/rebuild.go"
)

echo "=== CI Gate G18: Rebuild / Convergence Safety ==="
echo ""

# -----------------------------------------------------------------------------
# CHECK 1 — SUBJECT RESOLUTION.  Missing subject = FAILURE, never a skip.
# -----------------------------------------------------------------------------
echo "1. Subject resolution (${#SUBJECTS[@]} declared)..."
for f in "${SUBJECTS[@]}"; do
    if [[ -f "$f" ]]; then
        pass "subject resolved: $f"
    else
        violation "SUBJECT_NOT_FOUND: '$f' is declared but does not exist. A guard whose subject is absent proves nothing."
    fi
done

# If subjects are unresolvable there is nothing to assert. Fail closed now
# rather than emitting a green verdict over an empty population.
if [[ $VIOLATIONS -gt 0 ]]; then
    echo ""
    echo "::error title=G18 rebuild-safety::$VIOLATIONS unresolved subject(s) — refusing to report a verdict over an incomplete population."
    exit 1
fi

TPL="install/nftables/nftables.conf.tpl"
FRAG="cli/lib/nftban/lib/nft_fragment.sh"
DDOS="cli/lib/nftban/core/nftban_ddos_classic.sh"

# -----------------------------------------------------------------------------
# CHECK 2 — BASE LAYER-0 IS PRESENT AND UNCONDITIONAL IN THE CANONICAL RENDER.
#   LAYER0_MODEL = ALWAYS_ON_BASE_PROTECTION (owner-frozen 2026-08-21):
#   DDOS_ENABLED gates the higher tier, NEVER the base layer.
#   Both families must carry each construct -> expect >= 2 occurrences.
# -----------------------------------------------------------------------------
echo ""
echo "2. Base Layer-0 present in the canonical render (both families)..."
check_base() {
    local label="$1" pattern="$2" n
    n="$(grep -cE -- "$pattern" "$TPL" || true)"
    if [[ "$n" -ge 2 ]]; then
        pass "$label present in both families ($n)"
    else
        violation "BASE_LAYER0_MISSING: '$label' found $n time(s) in $TPL, expected >=2 (IPv4 + IPv6). Base Layer-0 is ALWAYS-ON and must never be removed from the canonical render."
    fi
}
check_base "invalid-state drop"      'ct state invalid .*drop'
check_base "SSH connlimit"           'ct count over __CT_LIMIT_SSH__'
check_base "per-source SYN meter"    'update @syn_meter_v[46]'

# The base layer must not become conditional on the higher-tier flag.
if grep -qE 'DDOS_ENABLED' "$TPL"; then
    violation "BASE_LAYER0_GATED: $TPL references DDOS_ENABLED. The base layer must not be gated on the higher-tier module flag."
else
    pass "canonical render does not gate the base layer on DDOS_ENABLED"
fi

# -----------------------------------------------------------------------------
# CHECK 3 — MODULE TEARDOWN CAPABILITY IS COMPLETE.
#   A disabled higher-tier module must not be left LIVE + HOOKED. The correct
#   teardown removes the JUMP and DELETES the CHAIN; a flush-only teardown
#   leaves an empty-but-hooked chain behind.
# -----------------------------------------------------------------------------
echo ""
echo "3. Module teardown capability (jump removal + chain delete)..."
# NOTE: the chain-delete pattern is written with [[:space:]] classes rather than
# literal spaces so this SEARCH STRING is not itself matched by the nft-write
# policy gate (scripts/ci/check-nft-writes.sh), whose WRITE pattern is
# `nft[[:space:]]+(add|delete|...)`. This file is a guard, not a call site.
# ⛔ Deliberately NOT solved by adding this file to that gate's allowlist:
#    AN ALLOWLISTED GUARD IS THE DEAD AUTHORITY IT EXISTS TO PREVENT.
if grep -q 'nft_fragment_remove_jump' "$FRAG" && grep -qE 'nft[[:space:]]+delete[[:space:]]+chain' "$FRAG"; then
    pass "nft_fragment_disable_module retains jump-removal and chain-delete"
else
    violation "TEARDOWN_INCOMPLETE: $FRAG no longer performs BOTH jump removal and chain delete. A flush-only teardown leaves disabled modules LIVE and HOOKED."
fi

# -----------------------------------------------------------------------------
# CHECK 4 — FLUSH-ONLY TEARDOWN RATCHET.
#   Four DDoS stages currently bypass the correct teardown (C-2, fixed in PR-4).
#   This is a RATCHET, not an assertion of the desired end state: the count may
#   go DOWN, never UP.
#
#   G18_FLUSH_ONLY_BASELINE  = 4
#   TEMPORARY_ACCEPTED_DEBT  = YES
#   OWNER                    = v1.229.7 PR-4 / C-2
#
#   PR-4 ACCEPTANCE: drive the baseline 4 -> 0, then REPLACE this ratchet with
#   the exact invariant:
#
#       FLUSH_ONLY_TEARDOWN_PATHS = 0
#
#   ⛔ DO NOT leave `<= 4` as the permanent invariant after PR-4. A ratchet that
#      outlives its debt silently licenses the defect it was pinning.
#
#   ⛔ The baseline is an EXPLICIT, INDEPENDENT EXPECTATION and is deliberately
#      hardcoded here. It MUST NOT be recalculated from whatever the
#      implementation currently contains -- otherwise a fifth bypass would
#      redefine its own accepted baseline and the ratchet would assert nothing.
#      SELF-DERIVED BASELINE = NO BASELINE.
# -----------------------------------------------------------------------------
echo ""
echo "4. Flush-only teardown ratchet..."
FLUSH_ONLY_BASELINE=4
n_flush="$(grep -cE '^\s*_nftban_ddos_(sanity|synproxy|prefix|classic)_remove_via_ipc\s*\(\)' "$DDOS" || true)"
if [[ "$n_flush" -le "$FLUSH_ONLY_BASELINE" ]]; then
    pass "flush-only module teardown paths: $n_flush (baseline $FLUSH_ONLY_BASELINE, must not grow)"
else
    violation "TEARDOWN_BYPASS_GREW: $n_flush flush-only teardown paths in $DDOS, baseline is $FLUSH_ONLY_BASELINE. New teardown paths must route through nft_fragment_disable_module."
fi

# -----------------------------------------------------------------------------
# SELF-TEST (G18-N4) — prove the accumulator is CONNECTED.
#   The previous implementation could not fail. This asserts that a discovered
#   violation actually reaches the exit code.
# -----------------------------------------------------------------------------
if [[ $SELFTEST -eq 1 ]]; then
    echo ""
    echo "SELFTEST: injecting a synthetic violation to prove the accumulator is connected..."
    before=$VIOLATIONS
    violation "SELFTEST synthetic violation (expected)"
    if [[ $VIOLATIONS -eq $((before + 1)) ]]; then
        echo "   PASS  accumulator incremented ($before -> $VIOLATIONS)"
        echo "   PASS  G18 self-test: a discovered violation reaches the verdict"
        exit 0
    fi
    echo "::error title=G18 rebuild-safety::SELFTEST FAILED — accumulator did not increment. The guard cannot fail and is TEST_INVALID."
    exit 1
fi

echo ""
echo "Summary"
echo "======="
if [[ $VIOLATIONS -gt 0 ]]; then
    echo "::error title=G18 rebuild-safety::G18 FAILED: $VIOLATIONS violation(s)"
    exit 1
fi

echo "G18: rebuild/convergence safety PASSED (${#SUBJECTS[@]} subjects asserted)"
echo ""
echo "Scope: static assertions over the declared subjects only."
echo "Runtime convergence (constructor matrix, package-native DEB/RPM) is proven on lab hosts."
