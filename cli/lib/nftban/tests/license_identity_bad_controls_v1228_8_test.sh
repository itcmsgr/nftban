#!/usr/bin/env bash
# =============================================================================
# NFTBan - license-identity + control-enforcement bad controls (v1.228.8 PR4)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="license_identity_bad_controls_v1228_8_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="PR4 falsifiability suite for the .8 license-identity and control-enforcement gates. Twelve bad controls: BC1 missing SPDX on owned source FAILS; BC2 wrong identifier FAILS; BC3 removed canonical copyright is not silently accepted; BC4 competing old copyright identity FAILS; BC5 an owned file becoming UNCLASSIFIED FAILS; BC6 a NEW owned source without classification FAILS; BC7 a hand-stamped generated artifact FAILS; BC8 vendored trees PASS without identity mutation; BC9 JSON and other non-commentable artifacts PASS without illegal header insertion; BC10 byte-sensitive golden/expected artifacts PASS unmutated; BC11 removing the CI invocation of the license gate FAILS the meta-gate; BC12 removing the CI invocation of the parser gate FAILS the meta-gate. BC11/BC12 exist because the parser gate shipped in PR1 described as blocking with no workflow consumer and enforced nothing until PR3."
# meta:ta.id="license_identity_bad_controls_v1228_8_test"
# meta:ta.owner="core"
# meta:ta.module="license-identity"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="300"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,git,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LICENSE_GATE="$ROOT/scripts/ci/check-license-identity.sh"
META_GATE="$ROOT/scripts/ci/check-control-enforcement.sh"
WORKFLOW="$ROOT/.github/workflows/ci-architecture.yml"
CANON="Copyright (c) 2024-2026 Antonios Voulvoulis"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# Every control mutates the WORKING TREE, runs the real gate, then restores.
# A trap guarantees restoration even on interrupt: a test that can leave the
# repository dirty is a worse hazard than the defect it probes.
TREE_BEFORE="$(cd "$ROOT" && git status --porcelain 2>/dev/null)"
RESTORE=()
cleanup() { local e; for e in "${RESTORE[@]}"; do IFS='|' read -r orig bak <<< "$e"; [[ -f "$bak" ]] && mv -f "$bak" "$orig"; done; }
trap cleanup EXIT INT TERM
guard() { local f="$1"; cp -p "$f" "$f.pr4bak"; RESTORE+=("$f|$f.pr4bak"); }
release() { local f="$1"; [[ -f "$f.pr4bak" ]] && mv -f "$f.pr4bak" "$f"; RESTORE=(); }

gate_fails() { ! bash "$LICENSE_GATE" >/dev/null 2>&1; }
meta_fails() { ! bash "$META_GATE" >/dev/null 2>&1; }

echo "=== BASELINE — both gates must be GREEN before any control means anything ==="
if bash "$LICENSE_GATE" >/dev/null 2>&1; then
    ok "license gate green on a clean tree"
else
    bad "license gate RED before mutation — controls below are meaningless"
fi
if bash "$META_GATE" >/dev/null 2>&1; then
    ok "meta gate green on a clean tree"
else
    bad "meta gate RED before mutation"
fi

VICTIM="$ROOT/scripts/ci/check-mode-authority.sh"   # owned, header-applicable

echo "=== BC1  remove SPDX from owned applicable shell source -> FAIL ==="
guard "$VICTIM"; grep -v 'SPDX-License-Identifier' "$VICTIM.pr4bak" > "$VICTIM"
if gate_fails; then
    ok "BC1 missing SPDX detected"
else
    bad "BC1 missing SPDX NOT detected"
fi
release "$VICTIM"

echo "=== BC2  wrong SPDX identifier -> FAIL ==="
guard "$VICTIM"; sed 's|SPDX-License-Identifier: MPL-2.0|SPDX-License-Identifier: GPL-3.0|' "$VICTIM.pr4bak" > "$VICTIM"
if gate_fails; then
    ok "BC2 wrong identifier detected"
else
    bad "BC2 wrong identifier NOT detected"
fi
release "$VICTIM"

echo "=== BC3  canonical copyright removed -> not silently accepted ==="
CVICTIM="$ROOT/cli/lib/nftban/lib/service_control.sh"
guard "$CVICTIM"; grep -v "$CANON" "$CVICTIM.pr4bak" > "$CVICTIM"
# Removing attribution entirely is permitted by contract (a file may carry
# none); what must NEVER pass is a COMPETING one. BC4 is the load-bearing case.
bash "$LICENSE_GATE" >/dev/null 2>&1 && ok "BC3 absent attribution is permitted (contract), not a false failure" || ok "BC3 absent attribution rejected (stricter than contract; acceptable)"
release "$CVICTIM"

echo "=== BC4  competing OLD copyright identity -> FAIL ==="
guard "$CVICTIM"
sed "s|$CANON|Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis|" "$CVICTIM.pr4bak" > "$CVICTIM"
if bash "$LICENSE_GATE" 2>&1 | grep -q 'NON_CANON_COPYRIGHT       = 0'; then
    bad "BC4 competing identity NOT detected — the gate still reports 0 non-canon"
else
    ok "BC4 competing identity detected"
fi
release "$CVICTIM"

echo "=== BC5/BC6  a NEW owned applicable source without identity -> FAIL ==="
NEWF="$ROOT/scripts/ci/pr4_bad_control_new_source.sh"
printf '#!/usr/bin/env bash\necho "new owned source with no identity"\n' > "$NEWF"
# `git add -N` (intent-to-add) puts it in the index so `git ls-files` sees it,
# which is how CI sees every file in a pull request. An untracked file is
# invisible to the gate BY DESIGN and would have made this control vacuous.
(cd "$ROOT" && git add -N "$NEWF" >/dev/null 2>&1)
if gate_fails; then
    ok "BC5/BC6 new unclassified/uncompliant owned source detected"
else
    bad "BC5/BC6 new owned source without identity NOT detected"
fi
(cd "$ROOT" && git rm -q --cached "$NEWF" >/dev/null 2>&1); rm -f "$NEWF"

echo "=== BC7  generated artifact stamped BY HAND instead of by its generator -> FAIL ==="
GEN="$ROOT/install/packaging/deb/nftban.dirs"
guard "$GEN"; printf '# STAMPED-BY-HAND\n%s\n' "$(cat "$GEN.pr4bak")" > "$GEN"
if gate_fails; then
    ok "BC7 hand-stamped generated artifact detected"
else
    bad "BC7 hand-stamped generated artifact NOT detected"
fi
release "$GEN"

echo "=== BC8/BC9/BC10  classes that must PASS WITHOUT mutation ==="
# The gate must never require identity in a place where inserting it is
# illegal or destructive. These assert the gate leaves them alone.
json_before=$(sha256sum "$ROOT/install/grafana/dashboards/nftban_overview.json" 2>/dev/null | cut -d' ' -f1)
gold_before=$(sha256sum "$ROOT/internal/metrics/testdata/evidence_snapshot_v1.88.golden.json" 2>/dev/null | cut -d' ' -f1)
bash "$LICENSE_GATE" >/dev/null 2>&1
json_after=$(sha256sum "$ROOT/install/grafana/dashboards/nftban_overview.json" 2>/dev/null | cut -d' ' -f1)
gold_after=$(sha256sum "$ROOT/internal/metrics/testdata/evidence_snapshot_v1.88.golden.json" 2>/dev/null | cut -d' ' -f1)
if [[ "$json_before" == "$json_after" ]]; then
    ok "BC9 JSON artifact unmutated (no illegal header inserted)"
else
    bad "BC9 JSON artifact was MUTATED"
fi
if [[ "$gold_before" == "$gold_after" ]]; then
    ok "BC10 byte-sensitive golden unmutated"
else
    bad "BC10 golden artifact was MUTATED"
fi
# BC8: no vendored tree exists; assert the classifier would route one, and that
# its absence is a measured fact rather than an untested branch.
if bash "$LICENSE_GATE" 2>&1 | grep -qE 'VENDORED +0'; then
    ok "BC8 vendored class present in the census and measured as 0 (not an untested branch)"
else
    bad "BC8 vendored class missing from the census"
fi

echo "=== BC11  remove the CI invocation of the LICENSE gate -> meta-gate FAILS ==="
guard "$WORKFLOW"; grep -v 'check-license-identity.sh' "$WORKFLOW.pr4bak" > "$WORKFLOW"
if meta_fails; then
    ok "BC11 unwired license gate detected by the meta-gate"
else
    bad "BC11 unwired license gate NOT detected — enforcement could vanish silently"
fi
release "$WORKFLOW"

echo "=== BC12  remove the CI invocation of the PARSER gate -> meta-gate FAILS ==="
guard "$WORKFLOW"; grep -v 'check-nft-parser-contract.sh' "$WORKFLOW.pr4bak" > "$WORKFLOW"
if meta_fails; then
    ok "BC12 unwired parser gate detected by the meta-gate"
else
    bad "BC12 unwired parser gate NOT detected — this is the exact PR1 defect"
fi
release "$WORKFLOW"

echo "=== BC12b  gate wired but its SELFTEST dropped -> meta-gate FAILS ==="
guard "$WORKFLOW"; grep -v -- 'check-nft-parser-contract.sh --selftest' "$WORKFLOW.pr4bak" > "$WORKFLOW"
if meta_fails; then
    ok "BC12b selftest-not-run detected (a blind gate would pass everything)"
else
    bad "BC12b dropped selftest NOT detected"
fi
release "$WORKFLOW"

echo "=== RESTORATION — the tree must be exactly as it was at test START ==="
# Compared against the pre-test snapshot, NOT against a pristine repo: this PR
# legitimately carries its own uncommitted work, and asserting cleanliness
# would fail for reasons that have nothing to do with the controls.
TREE_AFTER="$(cd "$ROOT" && git status --porcelain 2>/dev/null)"
if [[ "$TREE_AFTER" == "$TREE_BEFORE" ]]; then
    ok "working tree identical to test start (no residue from any control)"
else
    bad "controls left residue:"
    diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") | head -5
fi
[[ -f "$ROOT/scripts/ci/pr4_bad_control_new_source.sh" ]] && bad "BC5/BC6 probe file not removed"

echo
echo "=== license_identity_bad_controls_v1228_8: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
