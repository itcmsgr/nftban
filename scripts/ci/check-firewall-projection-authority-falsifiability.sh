#!/usr/bin/env bash
# =============================================================================
# NFTBan - falsifiability control for the firewall projection authority guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-firewall-projection-authority-falsifiability"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-03"
# meta:description="Proves check-firewall-projection-authority.sh is DISCRIMINATING for the rules it enforces on the CURRENT tree — P1 schema singularity, P3 enforcement equivalence, P5 rendered-schema parse — by injecting each defect class it claims to catch and requiring a FAIL that NAMES THAT RULE. Scope is deliberately limited to P1/P3/P5: the guard states plainly that it does not enforce single-substitution-authority, rule-comment drift, or any boot-projection rule, because those subjects either do not exist on this tree or do not pass on it. When those rules are added, this control must be extended in the SAME change — a guard arm without a falsifiability arm is an unproven claim. Every fixture's presence is asserted before any verdict is read, every mutation is restored, and the tree is verified byte-identical afterwards. Static only — mutates files in place, invokes no host."
# meta:input="scripts/ci/check-firewall-projection-authority.sh and the three sources it reads"
# meta:output="PASS/FAIL per injection; exit 0 when the guard discriminates on every case"
# meta:depends="bash,grep,sed,cmp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,cmp"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

GUARD="scripts/ci/check-firewall-projection-authority.sh"
TPL="install/nftables/nftables.conf.tpl"
CONF="install/nftables/nftables.conf"
RENDER="cli/lib/nftban/cli/cmd_firewall.sh"
EXTRA="install/nftables/.fpa-falsifiability-second-schema.nft"   # created/removed per arm

PASS=0; FAIL=0; SKIP=0
ok(){   PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no(){   FAIL=$((FAIL+1)); printf '  [FAIL] %s%s\n' "$1" "${2:+ — $2}"; }
skip(){ SKIP=$((SKIP+1)); printf '  [SKIP] %s%s\n' "$1" "${2:+ — $2}"; }

echo "=== check-firewall-projection-authority-falsifiability (P1 P3 P5 only) ==="
[[ -x "$GUARD" ]] || { echo "  FATAL: $GUARD missing/not executable"; exit 2; }
for f in "$TPL" "$CONF" "$RENDER"; do
    [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }
done

BT="$(mktemp)"; BC="$(mktemp)"; BR="$(mktemp)"
cp "$TPL" "$BT"; cp "$CONF" "$BC"; cp "$RENDER" "$BR"
restore(){ cp "$BT" "$TPL"; cp "$BC" "$CONF"; cp "$BR" "$RENDER"; rm -f "$EXTRA"; }
trap 'restore; rm -f "$BT" "$BC" "$BR"' EXIT

# A guard run is only evidence if the FIXTURE actually landed. Assert presence
# before reading any verdict: an injection that silently no-ops turns every
# assertion after it into a vacuous pass.
fixture_present(){ # file, marker
    [[ -f "$1" ]] && grep -q "$2" "$1"
}

# EXPECTED_G1_RULE_FAILED: the guard must not merely exit non-zero, it must fail
# THE RULE UNDER TEST. A guard that fails for an unrelated reason proves nothing
# about the rule this arm claims to falsify.
run_guard(){ bash "$GUARD" 2>&1; }

arm_fail(){ # name, rule-token, expected-message-fragment
    local name="$1" rule="$2" frag="$3" out rc
    out="$(run_guard)"; rc=$?
    if (( rc == 0 )); then
        no "$name" "guard PASSED on an injected $rule defect"
        return
    fi
    if grep -qF "$frag" <<<"$out"; then
        ok "$name"
    else
        no "$name" "guard failed, but not on $rule (expected: '$frag')"
        grep -E '^\s*\[FAIL\]' <<<"$out" | head -3 | sed 's/^/           /'
    fi
}

# ---------------------------------------------------------------------------
# NC-P1 — a SECOND placeholder-bearing schema is a second firewall authority.
# ---------------------------------------------------------------------------
restore
printf 'table ip nftban {\n\tct count over __CT_LIMIT_SSH__\n}\n' > "$EXTRA"
if fixture_present "$EXTRA" '__CT_LIMIT_SSH__'; then
    arm_fail "NC-P1 second placeholder-bearing schema -> P1 must FAIL" \
             "P1" "P1 canonical-schema singularity violated"
else
    no "NC-P1" "fixture absent after injection — assertion would be vacuous"
fi
restore

# ---------------------------------------------------------------------------
# NC-P3a — the shipped artifact ENFORCEMENT-diverges from the canonical schema.
# The injected line must survive enforce(): not a comment, and it carries no
# `comment "..."` string, so it is genuine enforcement drift.
# ---------------------------------------------------------------------------
restore
printf '\ntable ip nftban_falsifiability_drift {\n}\n' >> "$CONF"
if fixture_present "$CONF" 'nftban_falsifiability_drift'; then
    arm_fail "NC-P3a enforcement drift in the shipped artifact -> P3 must FAIL" \
             "P3" "P3 ENFORCEMENT DRIFT"
else
    no "NC-P3a" "fixture absent after injection — assertion would be vacuous"
fi
restore

# ---------------------------------------------------------------------------
# NC-P3b — GUARD INPUT SHAPE. P3 reads the install-time fallbacks FROM the render
# authority rather than hardcoding them, precisely so a shape change fails loudly
# instead of silently comparing against stale values. Falsify that promise.
# ---------------------------------------------------------------------------
restore
sed -i 's/local _ct_ssh=[0-9]\+ _ct_http=[0-9]\+ _ct_mail=[0-9]\+/local _ct_renamed=1 _ct_http2=1 _ct_mail2=1/' "$RENDER"
if ! grep -qE 'local _ct_ssh=[0-9]+ _ct_http=[0-9]+ _ct_mail=[0-9]+' "$RENDER"; then
    arm_fail "NC-P3b render-authority input shape changed -> P3 must FAIL LOUDLY" \
             "P3" "P3 cannot read the install-time fallbacks"
else
    no "NC-P3b" "fixture absent after injection — assertion would be vacuous"
fi
restore

# ---------------------------------------------------------------------------
# NC-P3c — an UNRENDERED placeholder must never reach the projection. A new
# placeholder the substitution does not know about is the shape of a schema that
# silently ships `__SOMETHING__` to the kernel.
# ---------------------------------------------------------------------------
restore
printf '\n# __FPA_FALSIFIABILITY_UNRENDERED__\n' >> "$TPL"
if fixture_present "$TPL" '__FPA_FALSIFIABILITY_UNRENDERED__'; then
    arm_fail "NC-P3c unrendered placeholder survives substitution -> P3 must FAIL" \
             "P3" "P3 unrendered placeholders remain"
else
    no "NC-P3c" "fixture absent after injection — assertion would be vacuous"
fi
restore

# ---------------------------------------------------------------------------
# NC-P5 — the rendered schema must PARSE. Inject the same syntactically invalid
# line into BOTH the template and the shipped artifact, so enforcement stays
# identical and P3 still passes: this isolates P5 as the only rule that can fail.
#
# ⛔ P5 SKIPS when nft is absent, or present but unprivileged with no namespace
#    available. A SKIP is not a PASS — absence of a verdict is not a verdict —
#    so this arm reports INCONCLUSIVE rather than claiming discrimination.
# ---------------------------------------------------------------------------
restore
BOGUS='this_is_not_valid_nft_syntax {'
printf '\n%s\n' "$BOGUS" >> "$TPL"
printf '\n%s\n' "$BOGUS" >> "$CONF"
if fixture_present "$TPL" 'this_is_not_valid_nft_syntax' && fixture_present "$CONF" 'this_is_not_valid_nft_syntax'; then
    out="$(run_guard)"
    if grep -qF 'P5 SKIPPED' <<<"$out"; then
        skip "NC-P5 invalid rendered schema" "P5 could not run here (no nft, or unprivileged with no namespace) — INCONCLUSIVE, not a pass"
    elif grep -qF 'P5 rendered canonical schema FAILS nft -c' <<<"$out"; then
        ok "NC-P5 syntactically invalid rendered schema -> P5 must FAIL"
    else
        no "NC-P5 syntactically invalid rendered schema -> P5 must FAIL" \
           "P5 neither failed nor skipped"
        grep -E '^\s*\[(FAIL|PASS|INFO)\] P5' <<<"$out" | head -2 | sed 's/^/           /'
    fi
else
    no "NC-P5" "fixture absent after injection — assertion would be vacuous"
fi
restore

# ---------------------------------------------------------------------------
# POSITIVE CONTROL + restoration proof.
# ---------------------------------------------------------------------------
if cmp -s "$BT" "$TPL" && cmp -s "$BC" "$CONF" && cmp -s "$BR" "$RENDER" && [[ ! -e "$EXTRA" ]]; then
    ok "tree restored byte-identical (template, shipped artifact, render authority; fixture file removed)"
else
    no "tree NOT restored byte-identical"
fi
if bash "$GUARD" >/dev/null 2>&1; then
    ok "guard PASSES on the restored tree"
else
    no "guard FAILS on the restored tree — the control has corrupted its own subject"
fi

echo
echo "=== fpa-falsifiability: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
(( FAIL == 0 ))
