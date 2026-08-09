#!/usr/bin/env bash
# =============================================================================
# NFTBan - Core ownership identity bad controls (v1.228.9 PR2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="core_ownership_identity_v1228_9_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-09"
# meta:description="Bad controls for the Core ownership-identity gate. Proves every competing ownership rendering fails regardless of CASE (NFTBAN / NFTBan / nftban / NFTban Project), that a required legal surface cannot be deleted or silently unregistered, that wrong years and a differing DEP-5 owner fail, and — the positive control that keeps the gate honest — that DEP-5's own grammar (Copyright: with no parenthesised c) PASSES, because the gate compares resolved holder/years/licence semantics rather than byte-identical strings. Case coverage exists because the original normaliser and the retired-form detector both matched NFTBAN but not NFTBan, so half the documents were silently left unfixed."
# meta:ta.id="core_ownership_identity_v1228_9_test"
# meta:ta.owner="core"
# meta:ta.module="legal-identity"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="scripts/ci/data/legal-identity-surfaces.tsv"
# meta:inventory.binaries="bash,git"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GATE="$ROOT/scripts/ci/check-core-ownership-identity.sh"
REG="$ROOT/scripts/ci/data/legal-identity-surfaces.tsv"
VICTIM="$ROOT/README.md"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

BEFORE="$(cd "$ROOT" && git status --porcelain)"
restore() { [[ -f /tmp/coi.bak ]] && mv -f /tmp/coi.bak "$RTARGET" 2>/dev/null; }
trap restore EXIT INT TERM

gate_fails() { ! bash "$GATE" >/dev/null 2>&1; }

if bash "$GATE" >/dev/null 2>&1; then
    ok "baseline: gate green on the clean tree"
else
    bad "baseline RED — every control below is meaningless"
fi

# --- competing ownership renderings, ALL CASES -------------------------------
# The normaliser and the retired-form detector originally matched NFTBAN but
# not NFTBan, so a case variant is exactly how the next divergence returns.
for form in \
    "NFTBAN Project / Antonios Voulvoulis" \
    "NFTBan Project / Antonios Voulvoulis" \
    "nftban Project / Antonios Voulvoulis" \
    "NFTban Project / Antonios Voulvoulis" \
    "NFTBan / Antonios Voulvoulis" \
    "NFTBan Project"
do
    RTARGET="$VICTIM"; cp "$VICTIM" /tmp/coi.bak
    python3 - "$VICTIM" "$form" <<'PY'
import sys
p,form=sys.argv[1],sys.argv[2]
s=open(p).read().replace("2024-2026 Antonios Voulvoulis", "2024-2026 "+form, 1)
open(p,'w').write(s)
PY
    if gate_fails; then ok "competing owner rejected: '$form'"; else bad "NOT rejected: '$form'"; fi
    mv -f /tmp/coi.bak "$VICTIM"
done

# --- year divergence ---------------------------------------------------------
RTARGET="$VICTIM"; cp "$VICTIM" /tmp/coi.bak
sed -i 's/2024-2026 Antonios Voulvoulis/2024-2025 Antonios Voulvoulis/' "$VICTIM"
if gate_fails; then ok "wrong year range rejected (2024-2025)"; else bad "wrong year range NOT rejected"; fi
mv -f /tmp/coi.bak "$VICTIM"

# --- required surface deleted ------------------------------------------------
RTARGET="$ROOT/NOTICE.md"; cp "$ROOT/NOTICE.md" /tmp/coi.bak
rm -f "$ROOT/NOTICE.md"
if gate_fails; then ok "deleting a required legal surface fails the gate"; else bad "missing required surface passed"; fi
mv -f /tmp/coi.bak "$ROOT/NOTICE.md"

# --- surface silently unregistered -------------------------------------------
RTARGET="$REG"; cp "$REG" /tmp/coi.bak
sed -i '/^NOTICE.md/d' "$REG"
if gate_fails; then ok "removing a surface from the registry fails (coverage, not silence)"; else bad "unregistered surface passed"; fi
mv -f /tmp/coi.bak "$REG"

# --- DEP-5 owner divergence --------------------------------------------------
RTARGET="$ROOT/packaging/deb/copyright"; cp "$RTARGET" /tmp/coi.bak
sed -i 's/Antonios Voulvoulis/Someone Else/' "$RTARGET"
if gate_fails; then ok "DEP-5 owner divergence rejected"; else bad "DEP-5 owner divergence NOT rejected"; fi
mv -f /tmp/coi.bak "$RTARGET"

# --- POSITIVE control: DEP-5 grammar must PASS -------------------------------
# `Copyright: 2024-2026 <holder>` has no parenthesised c. If this ever fails,
# the gate has become a byte-equality grep and is forcing invalid metadata.
# NOT `grep -q` downstream of a pipe: under `set -o pipefail` it exits on first
# match, the upstream gate dies with EPIPE, and the pipeline reports failure —
# which would fail this control while the gate was behaving correctly.
if [[ "$(bash "$GATE" 2>&1 | grep -cF 'packaging/deb/copyright (dep5) resolves to holder=Antonios Voulvoulis' || true)" -gt 0 ]]; then
    ok "DEP-5 grammar passes without '(c)' — gate is semantic, not byte-equality"
else
    bad "DEP-5 grammar rejected — the gate has regressed to string matching"
fi

AFTER="$(cd "$ROOT" && git status --porcelain)"
if [[ "$BEFORE" == "$AFTER" ]]; then ok "tree restored to its pre-test state"; else bad "controls left residue"; fi

echo
echo "=== core_ownership_identity_v1228_9: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
