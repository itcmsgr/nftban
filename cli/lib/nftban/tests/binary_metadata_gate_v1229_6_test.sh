#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.6 — A BLOCKING PROPERTY MUST BE CHECKED BEFORE THE ACTION IT BLOCKS
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="binary-metadata-gate-v1229-6-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="v1.229.5 published with nftban-core carrying vcs.modified=true. Absence of +dirty was a declared release stop condition, but it existed only in a post-publication witness, so every machine gate passed and the release went out. Asserts the pre-publication gate rejects a dirty build tree, rejects a compiler that is not the canonical go.mod version, rejects unreadable or absent metadata, and refuses partial coverage."
# meta:inventory.files=".github/workflows/release.yml,scripts/ci/data/release-binary-witness-subjects.tsv,go.mod"
# meta:inventory.privileges="none"
# meta:ta.id="binary_metadata_gate_v1229_6_test"
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
#   ⛔ THE RULE THIS ENCODES:
#
#        POST-PUBLICATION WITNESS CANNOT ENFORCE A PRE-PUBLICATION REQUIREMENT
#
#      RELEASE WITNESS = confirmation.  RELEASE GATE = enforcement.
#      A required release property needs BOTH when post-publication confirmation matters.
#
#   ⛔ MEASURED across the SAME third-party builder path:
#        v1.229.3  nftban-core  go1.25.12  vcs.modified=true
#        v1.229.5  nftban-core  go1.25.13  vcs.modified=true
#      Cause: builder_go_slsa3.yml runs `go mod vendor` in the project checkout before
#      compiling; vendor/ was untracked, so the worktree was dirty at the build instant.
#      ⛔ A DIFFERENT PRODUCER from the __pycache__ defect fixed for our own build path.
#
#   ⛔ OBSERVATION ONLY. Metadata is read with grep. No shipped binary is executed here,
#      matching the gate's own constraint.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/release.yml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== shipped binary metadata gate (v1.229.6) ==="
[[ -f "$WF" ]] || { echo "  SUBJECT_NOT_FOUND: $WF"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

# ---- ORDER · the gate must precede publication ------------------------------------
ORDER="$(python3 - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
names = [str(s.get('name','')) for s in d['jobs']['verify-release']['steps']]
gi = next((i for i,n in enumerate(names) if n.startswith('Gate 4')), -1)
pi = next((i for i,n in enumerate(names) if 'publish release' in n), -1)
print("%d %d" % (gi, pi))
PY
)"
set -- $ORDER
if [[ "${1:--1}" -ge 0 && "${2:--1}" -ge 0 && "${1}" -lt "${2}" ]]; then
    pass "ORDER the metadata gate runs BEFORE publication (step $((${1}+1)) < step $((${2}+1)))"
    info "⛔ this ordering IS the fix — v1.229.5 checked the same property only afterwards"
else
    fail "ORDER the metadata gate does not precede publication (gate=${1} publish=${2})"
    echo "RESULT: FAIL"; exit 1
fi

# ---- extract the production gate ---------------------------------------------------
python3 - "$WF" "$TMP/gate4.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for st in d['jobs']['verify-release']['steps']:
    if str(st.get('name','')).startswith('Gate 4'):
        open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
[[ -s "$TMP/gate4.sh" ]] || { fail "G0 could not extract Gate 4"; echo "RESULT: FAIL"; exit 1; }
pass "G0 gate logic extracted from the production workflow"
bash -n "$TMP/gate4.sh" 2>/dev/null && pass "G0b extracted block is syntactically valid" \
                                    || { fail "G0b extracted block has a syntax error"; echo "RESULT: FAIL"; exit 1; }
# ⛔ NONZERO_TEST_RC != EXPECTED FAILURE PROVEN.

ABS="/tmp/release-verify"
grep -qF "$ABS" "$TMP/gate4.sh" || { fail "G0c gate no longer references $ABS — relocation would be vacuous"; echo "RESULT: FAIL"; exit 1; }
sed -i "s|${ABS}|\$PWD/dist|g" "$TMP/gate4.sh"
pass "G0c artifact directory relocated to the per-case sandbox"

# ---- fixtures ----------------------------------------------------------------------
# A fixture is a FILE CONTAINING THE METADATA STRINGS the gate greps for. It is never
# executed — matching the gate's own observation-only constraint.
mk(){
    local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d/dist" "$d/scripts/ci/data"
    printf 'module github.com/itcmsgr/nftban\n\ngo 1.25.13\n' > "$d/go.mod"
    printf '# fixture\nsubject\tnftband-linux-amd64\tbuild-checksum\nsubject\tnftban-core-linux-amd64\tslsa-provenance\nexpected_total\t2\n' \
        > "$d/scripts/ci/data/release-binary-witness-subjects.tsv"
    printf '%s' "$d"
}
bin(){ # $1 dir  $2 name  $3 compiler  $4 modified-value
    { printf 'ELFish padding\n'; printf '%s\n' "$3"; printf 'vcs.revision=%040d\n' 0; printf 'vcs.modified=%s\n' "$4"; } > "$1/dist/$2"
}
run_g(){ ( cd "$1" && GITHUB_WORKSPACE="$1" bash "$TMP/gate4.sh" 2>&1 ); }
rc_g(){  ( cd "$1" && GITHUB_WORKSPACE="$1" bash "$TMP/gate4.sh" >/dev/null 2>&1 ); echo $?; }

# ---- POSITIVE ----------------------------------------------------------------------
d="$(mk pos)"; bin "$d" nftband-linux-amd64 go1.25.13 false; bin "$d" nftban-core-linux-amd64 go1.25.13 false
out="$(run_g "$d")"; rc="$(rc_g "$d")"
if [[ "$rc" -eq 0 ]]; then
    pass "POS clean tree + canonical compiler on every subject -> PASS"
else
    fail "POS the shipped-clean shape did not pass (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -5
fi

# ---- N1 · LOAD-BEARING · vcs.modified=true must block ------------------------------
d="$(mk n1)"; bin "$d" nftband-linux-amd64 go1.25.13 false; bin "$d" nftban-core-linux-amd64 go1.25.13 true
out="$(run_g "$d")"; rc="$(rc_g "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Dirty build tree::' <<<"$out"; then
    pass "N1 vcs.modified=true -> FAIL, publication unreachable"
    info "⛔ this is the exact v1.229.5 state, which published because no gate existed"
else
    fail "N1 a dirty build tree did not block publication (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- N2 · wrong compiler ------------------------------------------------------------
d="$(mk n2)"; bin "$d" nftband-linux-amd64 go1.25.13 false; bin "$d" nftban-core-linux-amd64 go1.25.12 false
out="$(run_g "$d")"; rc="$(rc_g "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Compiler mismatch::' <<<"$out"; then
    pass "N2 compiler != canonical go.mod version -> FAIL (v1.229.3 shipped go1.25.12)"
else
    fail "N2 a wrong compiler did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- N3 · metadata unreadable / absent ---------------------------------------------
d="$(mk n3)"; bin "$d" nftband-linux-amd64 go1.25.13 false
printf 'no go build metadata here at all\n' > "$d/dist/nftban-core-linux-amd64"
out="$(run_g "$d")"; rc="$(rc_g "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Binary metadata unreadable::' <<<"$out"; then
    pass "N3 unreadable metadata -> FAIL (⛔ UNKNOWN IS NOT PASS)"
else
    fail "N3 unreadable metadata did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- N4 · declared subject absent ---------------------------------------------------
d="$(mk n4)"; bin "$d" nftband-linux-amd64 go1.25.13 false
out="$(run_g "$d")"; rc="$(rc_g "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Binary metadata subject missing::' <<<"$out"; then
    pass "N4 declared subject absent -> FAIL (ABSENCE IS NOT A SKIP)"
else
    fail "N4 an absent subject did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- N5 · declaration missing --------------------------------------------------------
d="$(mk n5)"; bin "$d" nftband-linux-amd64 go1.25.13 false; bin "$d" nftban-core-linux-amd64 go1.25.13 false
rm -f "$d/scripts/ci/data/release-binary-witness-subjects.tsv"
out="$(run_g "$d")"; rc="$(rc_g "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Binary metadata declaration missing::' <<<"$out"; then
    pass "N5 missing declaration -> FAIL (⛔ MISSING DECLARATION != EMPTY POPULATION)"
else
    fail "N5 a missing declaration did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- REAL · the actual published v1.229.5 binary must be rejected -------------------
# ⛔ THE LOAD-BEARING INVERSION. A fixture proves the gate can fail; only the real
#    artifact proves it fails on the state that actually shipped. Network-optional: if
#    the artifact is not available locally this is reported NOT_OBSERVED, never a pass.
REAL="${NFTBAN_V1229_5_CORE:-}"
if [[ -z "$REAL" ]]; then
    for c in /tmp/claude-1002/*/*/scratchpad/p5/nftban-core-linux-amd64 "$ROOT/../nftban-core-linux-amd64"; do
        [[ -f "$c" ]] && { REAL="$c"; break; }
    done
fi
if [[ -n "$REAL" && -f "$REAL" ]]; then
    d="$(mk real)"; bin "$d" nftband-linux-amd64 go1.25.13 false
    cp "$REAL" "$d/dist/nftban-core-linux-amd64"
    out="$(run_g "$d")"; rc="$(rc_g "$d")"
    if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Dirty build tree::' <<<"$out"; then
        pass "REAL the published v1.229.5 nftban-core is REJECTED by this gate"
        # ⛔ Read the value FROM THE SUBJECT, not from the gate's combined output: the
        #    output also contains the clean fixture's line, and `head -1` picked that one,
        #    reporting vcs.modified=false for a binary that is demonstrably true.
        info "published artifact carries $(grep -aoE 'vcs\.modified=(true|false)' "$REAL" | sort -u | paste -sd, -) — it shipped past the missing gate"
    else
        fail "REAL the published v1.229.5 binary was NOT rejected (rc=$rc)"
        sed 's/^/          /' <<<"$out" | tail -4
    fi
else
    info "REAL NOT_OBSERVED: published v1.229.5 nftban-core not available locally."
    info "⛔ Reported as NOT_OBSERVED, never as a pass. Set NFTBAN_V1229_5_CORE to run it."
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
