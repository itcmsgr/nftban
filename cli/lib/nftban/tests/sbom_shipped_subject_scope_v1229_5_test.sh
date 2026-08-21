#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.5 — THE SBOM DESCRIBES WHAT SHIPS, NOT WHAT WAS DOWNLOADED
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="sbom-shipped-subject-scope-v1229-5-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="v1.229.4's published SBOM inventoried slsa-builder-go-linux-amd64 as release content and attributed a go1.23.1 stdlib to a release built with 1.25.13, because SBOM generation scanned the whole workspace and R2 moved the SLSA builder's artifacts into it. Asserts the SBOM subject population is the assembled shipped-payload directory, that it is not the workspace root or an ancestor of the raw artifact download directory, and that the payload is filled by declared copies rather than a catch-all."
# meta:inventory.files=".github/workflows/release.yml"
# meta:inventory.privileges="none"
# meta:ta.id="sbom_shipped_subject_scope_v1229_5_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="core"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   ⛔ SUBJECT SELECTION, NOT SYMPTOM FILTERING. The wrong fixes here are:
#        * dropping packages whose version is "go1.23.1"
#        * excluding "slsa-builder" by name
#        * accepting multiple stdlib versions in the witness
#      Each leaves the next build tool to be inventoried silently. The population
#      itself must be the shipped payload.
#
#   ⛔ MEASURED (published artifacts):
#        v1.229.3   202 packages   0 slsa-builder refs   stdlib go1.25.12
#        v1.229.4   415 packages   1 slsa-builder ref    stdlib go1.23.1 + go1.25.13
#      Package COUNT is diagnostic evidence, never the guard — a count assertion would
#      fail on ordinary dependency changes and pass on a differently-named build tool.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="${1:-$ROOT/.github/workflows/release.yml}"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== SBOM shipped-subject scope (v1.229.5) ==="
[[ -f "$WF" ]] || { echo "  SUBJECT_NOT_FOUND: $WF"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

OUT="$(python3 - "$WF" <<'PY'
import sys, yaml, os
d = yaml.safe_load(open(sys.argv[1]))
job = (d.get('jobs') or {}).get('create-release') or {}
steps = job.get('steps') or []

sbom = next((s for s in steps
             if 'sbom-action@' in str(s.get('uses', '')) and (s.get('with') or {}).get('path')), None)
if sbom is None:
    print("ERR\tno SBOM generation step with a path was found in create-release")
    raise SystemExit
scan = str((sbom.get('with') or {}).get('path', '')).strip().rstrip('/')
print("SCAN\t%s" % (scan or '<empty>'))

# where do RAW downloaded artifacts land?
dl = [s for s in steps if 'download-artifact' in str(s.get('uses', ''))]
raw = []
for s in dl:
    p = str((s.get('with') or {}).get('path', '')).strip().rstrip('/')
    if p:
        raw.append(p)
print("RAW\t%s" % (",".join(raw) or '<none>'))

def covers(scan, other):
    """True if scanning `scan` would also walk `other`."""
    if scan in ('.', '', './'):
        return True
    s = os.path.normpath(scan); o = os.path.normpath(other)
    return s == o or o.startswith(s + os.sep)

for r in raw:
    if covers(scan, r):
        print("COVERS\t%s" % r)

# is the scanned dir filled by DECLARED copies rather than a catch-all?
blob = "\n".join((s.get('run') or '') for s in steps)
decl = ('find all-packages -name "*.rpm"' in blob and
        'find all-packages -name "*.deb"' in blob and
        'for binary in' in blob)
print("DECLARED_FILL\t%s" % ("yes" if decl else "no"))
print("SCAN_IS_ROOT\t%s" % ("yes" if scan in ('.', '', './') else "no"))
PY
)"
[[ -n "$OUT" ]] || { fail "the evaluator produced no output — ⛔ an empty result is NOT a pass"; echo "RESULT: FAIL"; exit 1; }

SCAN=$(awk -F'\t' '$1=="SCAN"{print $2}' <<<"$OUT")
RAW=$(awk -F'\t' '$1=="RAW"{print $2}' <<<"$OUT")
ISROOT=$(awk -F'\t' '$1=="SCAN_IS_ROOT"{print $2}' <<<"$OUT")
DECLFILL=$(awk -F'\t' '$1=="DECLARED_FILL"{print $2}' <<<"$OUT")
COVERS=$(awk -F'\t' '$1=="COVERS"{print $2}' <<<"$OUT")
ERR=$(awk -F'\t' '$1=="ERR"{print $2}' <<<"$OUT")

[[ -n "$ERR" ]] && { fail "$ERR"; echo "RESULT: FAIL"; exit 1; }
info "SBOM scans: $SCAN   raw artifact dir(s): $RAW"

# ---- S1 · the SBOM must not scan the workspace root -------------------------------
if [[ "$ISROOT" == "no" ]]; then
    pass "S1 the SBOM scans a specific directory, not the workspace root"
else
    fail "S1 the SBOM scans the workspace root ('$SCAN') — every artifact downloaded during orchestration becomes release content"
    info "⛔ this is the v1.229.4 shape: the SLSA builder binary was inventoried as shipped"
fi

# ---- S2 · the scanned dir must not contain the raw artifact drop -------------------
if [[ -z "$COVERS" ]]; then
    pass "S2 the SBOM scope does not cover the raw artifact download directory"
    info "build tooling delivered as a workflow artifact cannot enter the shipped SBOM"
else
    fail "S2 the SBOM scope covers the raw download directory:"
    sed 's/^/          /' <<<"$COVERS"
    info "⛔ SUBJECT SELECTION defect — not something to fix by filtering package names"
fi

# ---- S3 · the shipped payload is filled by declared copies -------------------------
# ⛔ Otherwise the scope is only accidentally narrow: a future catch-all copy into the
#    payload directory would reintroduce the defect while S1/S2 still passed.
if [[ "$DECLFILL" == "yes" ]]; then
    pass "S3 the shipped payload is assembled by declared copies (rpm, deb, named binaries)"
else
    fail "S3 the shipped payload is not assembled from declared subjects — scope would be incidental"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
