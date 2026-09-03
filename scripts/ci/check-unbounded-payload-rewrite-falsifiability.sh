#!/usr/bin/env bash
# =============================================================================
# NFTBan - falsifiability control for the unbounded-payload-rewrite guard (G2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-unbounded-payload-rewrite-falsifiability"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-03"
# meta:description="Proves check-unbounded-payload-rewrite.sh is DISCRIMINATING rather than merely quiet. G2 ships with KNOWN_VIOLATIONS=0, which is exactly the state in which a broken matcher is indistinguishable from a clean tree — so its passing result is worthless without this control. Injects a violation and requires FAIL; injects the two lookalikes the matcher must tolerate (nft's PLURAL name-listing subcommands, which are bounded by object count, and the assignment/TRANSFORMATION form, which is not a predicate at all) and requires PASS; then injects the SAME fixture at the SAME position changed only from plural to singular and requires FAIL, which is what proves the two PASSes came from the discriminator and not from an unreachable injection point. Every mutation is restored immediately and the tree is verified byte-identical afterwards. Static only — mutates files in place, invokes no host."
# meta:input="scripts/ci/check-unbounded-payload-rewrite.sh and the sources it reads"
# meta:output="PASS/FAIL per injection; exit 0 when the guard discriminates on every case"
# meta:depends="bash,grep,sed,cmp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,cmp"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
GUARD="scripts/ci/check-unbounded-payload-rewrite.sh"
SUBJECT="cli/lib/nftban/core/nftban_ddos_classic.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
no(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1${2:+ — $2}"; }
echo "=== check-unbounded-payload-rewrite-falsifiability ==="
[[ -x "$GUARD"   ]] || { echo "  FATAL: $GUARD missing/not executable"; exit 2; }
[[ -f "$SUBJECT" ]] || { echo "  FATAL: $SUBJECT missing"; exit 2; }

BAK="$(mktemp)"; cp "$SUBJECT" "$BAK"
restore(){ cp "$BAK" "$SUBJECT"; }
trap 'restore; rm -f "$BAK"' EXIT

# Inject a fixture immediately after the first top-level function header, and
# PROVE it landed. An injection that silently no-ops turns every subsequent
# assertion into a vacuous pass.
inject(){
    python3 - "$SUBJECT" "$1" <<'PY'
import sys, re
path, body = sys.argv[1], sys.argv[2]
s = open(path).read()
m = re.search(r'^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{\s*$', s, re.M)
if not m:
    sys.exit("INJECTION_FAILED: no top-level function header found")
open(path, 'w').write(s[:m.end()] + "\n" + body + s[m.end():])
PY
}
guard_fails(){ bash "$GUARD" >/dev/null 2>&1; [[ $? -ne 0 ]]; }

arm(){ # name, expect(fail|pass), marker, body
    local name="$1" expect="$2" marker="$3" body="$4"
    restore
    if ! inject "$body"; then no "$name" "fixture could not be injected"; return; fi
    if ! grep -q "$marker" "$SUBJECT"; then no "$name" "fixture absent after injection — assertion would be vacuous"; restore; return; fi
    if guard_fails; then
        [[ "$expect" == fail ]] && ok "$name" || no "$name" "guard FAILED on a construct it must tolerate"
    else
        [[ "$expect" == pass ]] && ok "$name" || no "$name" "guard PASSED on a construct it must reject"
    fi
    restore
}

arm "violation: singular \`list ruleset\` rewritten for a boolean -> FAIL" fail '_fx_viol' \
'    local _fx_viol
    _fx_viol=$(nft list ruleset 2>/dev/null) || _fx_viol=""
    [[ -z "${_fx_viol//[[:space:]]/}" ]] && return 2'

arm "violation: the [[:blank:]] variant is the SAME antipattern -> FAIL" fail '_fx_blank' \
'    local _fx_blank
    _fx_blank=$(nft list ruleset 2>/dev/null) || _fx_blank=""
    [[ -z "${_fx_blank//[[:blank:]]/}" ]] && return 2'

arm "lookalike: PLURAL \`list sets\` is bounded by object count -> PASS" pass '_fx_plural' \
'    local _fx_plural
    _fx_plural=$(nft list sets 2>/dev/null) || _fx_plural=""
    [[ -z "${_fx_plural//[[:space:]]/}" ]] && return 2'

arm "lookalike: TRANSFORMATION (assignment, not a predicate) -> PASS" pass '_fx_tf' \
'    local _fx_tf
    _fx_tf=$(nft list ruleset 2>/dev/null) || _fx_tf=""
    _fx_tf=${_fx_tf//[[:space:]]/}'

# CONTROL OF THE CONTROL. Same shape and same injection point as the plural arm,
# changed ONLY from `list sets` to `list set <obj>`. If this does not FAIL, the
# two PASSes above proved nothing about the discriminator.
arm "control: same fixture, SINGULAR \`list set\` -> FAIL" fail '_fx_plural' \
'    local _fx_plural
    _fx_plural=$(nft list set ip nftban blacklist_ipv4 2>/dev/null) || _fx_plural=""
    [[ -z "${_fx_plural//[[:space:]]/}" ]] && return 2'

restore
if cmp -s "$BAK" "$SUBJECT"; then ok "tree restored byte-identical"; else no "tree NOT restored"; fi
if bash "$GUARD" >/dev/null 2>&1; then ok "guard PASSES on the restored tree (KNOWN_VIOLATIONS=0)"
else no "guard FAILS on the restored tree"; fi

echo
echo "=== falsifiability: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
