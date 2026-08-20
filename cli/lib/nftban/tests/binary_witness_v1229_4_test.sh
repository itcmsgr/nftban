#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 PR-D — SHIPPED BINARIES MUST BE WITNESSED, NOT ASSUMED
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="binary-witness-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-20"
# meta:description="PR-D. Source-mode govulncheck cannot close the release claim: F1 measured the same subject as 5 error / 2 note in source mode and 7 error / 0 note in binary mode on the same day, because the two modes answer different questions and the binary is what ships. Asserts the release witness declares its subject population independently, fails on a missing subject, fails on an unparseable or absent artifact, treats a non-zero scanner status as a TOOL failure rather than a finding count, and cannot pass with a partial population. R2 added nftban-core-linux-amd64 as a second declared subject, so the witness covers both shipped binaries."
# meta:inventory.files=".github/workflows/release.yml,scripts/ci/data/release-binary-witness-subjects.tsv"
# meta:inventory.privileges="none"
# meta:ta.id="binary_witness_v1229_4_test"
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
#   ⛔ MODE CHANGES SEMANTICS (F1, same subject, same tool, same day):
#        source mode   error = REACHABLE from this module's code   -> 5 error / 2 note
#        binary mode   error = symbol PRESENT in the binary        -> 7 error / 0 note
#      This witness runs BINARY mode, so its claim is "present in the shipped artifact".
#      ⛔ Never quote it as source-mode reachability, or the reverse.
#
#   ⛔ FOUND != EXPECTED. The subject population is declared in a hand-maintained file and
#      READ, never derived from whatever was downloaded — the same anti-tautology rule the
#      SLSA subject declaration exists to enforce, and the shape whose absence let
#      nftban-core silently vanish from SHA256SUMS.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/release.yml"
DECL="$ROOT/scripts/ci/data/release-binary-witness-subjects.tsv"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== shipped-binary witness (v1.229.4 PR-D) ==="
for f in "$WF" "$DECL"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "RESULT: FAIL"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

python3 - "$WF" "$TMP/witness.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job in (d.get('jobs') or {}).values():
    if not isinstance(job, dict): continue
    for st in job.get('steps') or []:
        if str(st.get('name','')).startswith('PR-D binary govulncheck witness'):
            open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
[[ -s "$TMP/witness.sh" ]] || { fail "G0 could not extract the PR-D witness step"; echo "RESULT: FAIL"; exit 1; }
pass "G0 witness logic extracted from the production workflow"
bash -n "$TMP/witness.sh" 2>/dev/null && pass "G0b extracted witness is syntactically valid" \
                                      || { fail "G0b extracted witness has a syntax error"; echo "RESULT: FAIL"; exit 1; }
# ⛔ NONZERO_TEST_RC != EXPECTED FAILURE PROVEN — without this precondition an invalid block
#    exits non-zero for every arm and each negative control "passes" for the wrong reason.

# ---- ORDER · the witness must precede publication ------------------------------
ORDER="$(python3 - "$WF" <<'PY'
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
j=(d.get('jobs') or {}).get('verify-release') or {}
wi=pi=-1
for i,st in enumerate(j.get('steps') or []):
    n=str(st.get('name',''))
    if n.startswith('PR-D binary govulncheck witness'): wi=i
    if 'publish release' in n: pi=i
print("%d %d"%(wi,pi))
PY
)"
set -- $ORDER
if [[ "${1:--1}" -ge 0 && "${2:--1}" -ge 0 && "${1}" -lt "${2}" ]]; then
    pass "ORDER the witness runs BEFORE publication (step $((${1}+1)) < step $((${2}+1)))"
    info "a witness after publication would detect, not prevent"
else
    fail "ORDER the witness does not precede publication (witness=${1} publish=${2})"
fi

# ---- the shipped declaration must be real, coherent and hand-maintained --------
DC=$(awk -F'\t' '$1=="subject" && NF>=2' "$DECL" | wc -l | tr -d ' ')
EC=$(awk -F'\t' '$1=="expected_total"{print $2; exit}' "$DECL" | tr -d '[:space:]')
if [[ "$DC" -gt 0 && "$DC" == "$EC" ]]; then
    pass "DECL declaration is non-empty and coherent (subjects=$DC expected_total=$EC)"
else
    fail "DECL declaration empty or incoherent (subjects=$DC expected_total=$EC)"
fi
if grep -qiE '^\s*(ls|find|grep|awk|python)' "$DECL"; then
    fail "DECL2 the declaration contains enumeration logic — it must be hand-maintained data"
else
    pass "DECL2 the declaration is declarative data, not a rediscovery of what was downloaded"
fi
# ⛔ R2 CLOSED THIS GAP, SO THE ARM MUST NOW ASSERT THE CLOSURE, NOT THE GAP.
#    Before R2 nftban-core could not be a subject: the SLSA builder ran in a separate
#    workflow triggered AFTER this one, so the artifact did not exist at witness time.
#    R2 made the builder a job of release.yml. ⛔ A bare `grep nftban-core` would be
#    satisfied by the COMMENT explaining the history — mention is not declaration.
#    Require a real subject row, so the witness cannot regress to covering one binary
#    while a comment claims otherwise.
if awk -F'\t' '$1=="subject" && $2=="nftban-core-linux-amd64"{f=1} END{exit !f}' "$DECL"; then
    pass "DECL3 nftban-core-linux-amd64 is a DECLARED SUBJECT — the R2 coverage gap is closed"
    info "the witness now covers BOTH shipped binaries, not just nftband"
else
    fail "DECL3 nftban-core-linux-amd64 is not a declared subject row — R2's coverage closure regressed"
fi

# ---- behavioural arms against the extracted logic -------------------------------
mk(){ local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d/scripts/ci/data" "$d/bin"; printf '%s' "$d"; }
decl(){ printf 'subject\t%s\nexpected_total\t%s\n' "$2" "$3" > "$1/scripts/ci/data/release-binary-witness-subjects.tsv"; }
# A stub go/govulncheck so the arms are hermetic: the CONTROL FLOW is under test, not the
# scanner's analysis. ⛔ The stub decides only rc and artifact shape, never the classification.
stub(){ # $1 dir  $2 gvc_rc  $3 sarif-content
    cat > "$1/bin/go" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  install) exit 0 ;;
  env)     echo "$STUB_GOPATH" ;;
  version) echo "x go1.25.13 linux/amd64" ;;
  *)       exit 0 ;;
esac
EOF
    mkdir -p "$1/gopath/bin"
    cat > "$1/gopath/bin/govulncheck" <<EOF
#!/usr/bin/env bash
out=""; for a in "\$@"; do case "\$prev" in -o) :;; esac; prev="\$a"; done
printf '%s' '$3'
exit $2
EOF
    chmod +x "$1/bin/go" "$1/gopath/bin/govulncheck"
}
run_w(){ ( cd "$1" && PATH="$1/bin:$PATH" STUB_GOPATH="$1/gopath" bash "$TMP/witness.sh" 2>&1 ); }
rc_w(){ ( cd "$1" && PATH="$1/bin:$PATH" STUB_GOPATH="$1/gopath" bash "$TMP/witness.sh" >/dev/null 2>&1 ); echo $?; }

# ⛔ TOOL PROSE != PROTOCOL SIGNAL. Each arm below binds to the producer's exact
#    `::error title=...::` signal, not to a phrase. Two reasons, both measured:
#    (1) R2's Gate 3 added "Checksum subject declaration missing" and "Required checksum
#        subject missing", so the old phrases 'declaration missing' and 'subject missing'
#        now each match TWO different producers — an arm could pass on the wrong one.
#    (2) a correct message for a state routinely contains the words of the state it
#        DENIES, so a bare phrase match hits the opposite sentence.
# W-N1 · declaration missing
d="$(mk n1)"; stub "$d" 0 '{}'
rm -f "$d/scripts/ci/data/release-binary-witness-subjects.tsv"
out="$(run_w "$d")"; rc="$(rc_w "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Binary witness declaration missing::' <<<"$out"; then
    pass "W-N1 missing declaration -> FAIL (⛔ MISSING DECLARATION != EMPTY POPULATION)"
else
    fail "W-N1 a missing declaration did not fail (rc=$rc)"
fi

# W-N2 · zero declared subjects
d="$(mk n2)"; stub "$d" 0 '{}'
printf 'expected_total\t0\n' > "$d/scripts/ci/data/release-binary-witness-subjects.tsv"
out="$(run_w "$d")"; rc="$(rc_w "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Binary witness population invalid::' <<<"$out"; then
    pass "W-N2 zero declared subjects -> FAIL (0 SUBJECTS != 0 FINDINGS)"
else
    fail "W-N2 an empty population did not fail (rc=$rc)"
fi

# W-N3 · declared subject was not downloaded
d="$(mk n3)"; stub "$d" 0 '{}'; decl "$d" "nftband-linux-amd64" 1
out="$(run_w "$d")"; rc="$(rc_w "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Binary witness subject missing::' <<<"$out"; then
    pass "W-N3 declared subject absent from the release -> FAIL (ABSENCE IS NOT A SKIP)"
else
    fail "W-N3 a missing artifact did not fail (rc=$rc)"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
