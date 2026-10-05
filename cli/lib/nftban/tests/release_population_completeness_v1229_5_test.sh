#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.5 — VERIFIED IS NOT PUBLISHED
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="release-population-completeness-v1229-5-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="v1.229.4 published a SHA256SUMS listing nftban-core-linux-amd64 while that artifact was absent from the release: it was built, provenance-verified, witnessed and checksummed, then never uploaded, because R2 deleted the workflow holding the repository's own upload step along with the third-party one. Asserts the sole publisher uploads every declared provenance-bearing subject and that publication is blocked while any checksummed or declared artifact is absent from the release."
# meta:inventory.files=".github/workflows/release.yml,scripts/ci/data/slsa-subjects.tsv"
# meta:inventory.privileges="none"
# meta:ta.id="release_population_completeness_v1229_5_test"
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
#   ⛔ TWO INVARIANTS, NOT ONE. R2 proved uniqueness of the publishing authority and
#      stopped there:
#
#          ONE_PUBLISHER                  held   — exactly one path could publish
#          COMPLETE_PUBLISHED_POPULATION  FAILED — that path uploaded 13 of 15 artifacts
#
#      Uniqueness of an authority says nothing about completeness of its output.
#
#   ⛔ EVERY GATE BEFORE PUBLICATION REASONS ABOUT FILES ON THE RUNNER. Gate 1, Gate 2,
#      the SLSA verifier, the PR-D witness and Gate 3 all passed legitimately on
#      v1.229.4 — the binary really was present in /tmp/release-verify. None of them
#      could observe that it never reached the release. The only assertion that can is
#      one made against the release itself, before the draft flag is cleared.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/release.yml"
DECL_SRC="$ROOT/scripts/ci/data/slsa-subjects.tsv"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== release population completeness (v1.229.5) ==="
for f in "$WF" "$DECL_SRC"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "RESULT: FAIL"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

# ---- S1 · STRUCTURAL · the sole publisher must upload the declared subject -------
# This is the arm that would have caught v1.229.4 by reading the workflow alone.
# ⛔ MENTION != UPLOAD. An earlier draft of this arm grepped the job for the literal
#    basename and "passed" on a COMMENT that named the artifact. The real property is
#    that the publish step DERIVES both names from the declaration and hands them to
#    `gh release upload` BEFORE the draft flag is cleared.
UPLOADS="$(python3 - "$WF" <<'PY'
import sys, yaml, re
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['verify-release']['steps']
# v1.234.0: this step completes the DRAFT; release-publish.yml is the only publisher.
pub = next((s for s in steps if 'complete the draft release' in str(s.get('name', ''))), None)
if pub is None:
    print("NO_PUBLISH_STEP yes"); raise SystemExit
run = pub.get('run') or ''
code = "\n".join(l for l in run.split("\n") if not l.lstrip().startswith('#'))

bin_var = re.search(r'(\w+)="\$\(awk[^\n]*\$1=="?subject"?[^\n]*print \$2', code)
prov_var = re.search(r'(\w+)="\$\(awk[^\n]*\$1=="?subject"?[^\n]*print \$3', code)
print("DERIVES_FROM_DECL", "yes" if ('slsa-subjects.tsv' in code and bin_var and prov_var) else "no")

bn = bin_var.group(1) if bin_var else "\x00"
pn = prov_var.group(1) if prov_var else "\x00"
up_lines = [l for l in code.split("\n") if 'gh release upload' in l]
# the upload may be a loop over both vars, or two direct invocations
loop = re.search(r'for\s+\w+\s+in\s+"\$\{?' + bn + r'\}?"\s+"\$\{?' + pn + r'\}?"', code)
print("UPLOADS_BOTH", "yes" if (loop and up_lines) or
      (any(bn in l for l in up_lines) and any(pn in l for l in up_lines)) else "no")

ui = code.find('gh release upload')
ci = code.find('Published population incomplete')
print("UPLOAD_BEFORE_CHECK", "yes" if (0 <= ui < ci) else "no")
# v1.234.0: the draft is completed here and NEVER published here.
print("NEVER_PUBLISHES", "yes" if '--draft=false' not in code else "no")
PY
)"
dd=$(awk '$1=="DERIVES_FROM_DECL"{print $2}' <<<"$UPLOADS")
ub=$(awk '$1=="UPLOADS_BOTH"{print $2}' <<<"$UPLOADS")
uo=$(awk '$1=="UPLOAD_BEFORE_CHECK"{print $2}' <<<"$UPLOADS")
np=$(awk '$1=="NEVER_PUBLISHES"{print $2}' <<<"$UPLOADS")
if [[ "$dd" == "yes" && "$ub" == "yes" && "$uo" == "yes" && "$np" == "yes" ]]; then
    pass "S1 the draft completer uploads BOTH declared artifacts before the completeness check, and never publishes"
    info "v1.229.4 failed here: no step in the job could upload either one"
else
    fail "S1 draft completer structure invalid (derives=$dd uploads-both=$ub upload-before-check=$uo never-publishes=$np)"
    info "⛔ VERIFIED IS NOT PUBLISHED — this is the exact v1.229.4 defect"
fi

# ---- S4 · release-publish.yml is the ONLY publisher, and it publishes only checked bytes --
# v1.234.0 (owner): users get exactly the RC-accepted files. Only release-publish.yml may
# clear the draft flag; it must never build, upload, replace or delete an asset, and its
# draft / tag->commit / every-asset-hash / SHA256SUMS checks must all precede the flip.
PUBWF="$ROOT/.github/workflows/release-publish.yml"
if [[ ! -f "$PUBWF" ]]; then
    fail "S4 release-publish.yml missing: no gated publisher"
else
    S4="$(python3 - "$PUBWF" "$ROOT/.github/workflows" <<'PY'
import sys, os, yaml
d = yaml.safe_load(open(sys.argv[1]))
code = "\n".join((s.get('run') or '') + "\n" + str(s.get('uses') or '')
                 for j in d['jobs'].values() for s in j['steps'])
code = "\n".join(l for l in code.split("\n") if not l.lstrip().startswith('#'))
flip = code.find('--draft=false')
def before(tok): i = code.find(tok); return 0 <= i < flip
ok = {
  'flips_draft': flip >= 0,
  'no_upload': 'gh release upload' not in code and 'action-gh-release' not in code,
  'no_delete': 'delete-asset' not in code and 'gh release delete' not in code,
  'no_checkout_or_build': 'actions/checkout' not in code and 'go build' not in code and 'build_nftban' not in code,
  'rc_gates_first': before('not PASS'),
  # the refusal itself, not the query (isDraft is also read again after the flip)
  'draft_check_first': before('"$is_draft" == "true"'),
  'tag_commit_first': before('/commits/'),
  # the comparison itself, not a mention (MANIFEST_SHA also appears in input validation)
  'manifest_first': before('== "$MANIFEST_SHA"'),
  'sha256sums_first': before('sha256sum -c SHA256SUMS'),
}
others = []
for f in sorted(os.listdir(sys.argv[2])):
    p = os.path.join(sys.argv[2], f)
    if f.endswith(('.yml', '.yaml')) and os.path.abspath(p) != os.path.abspath(sys.argv[1]):
        body = "\n".join(l for l in open(p).read().split("\n") if not l.lstrip().startswith('#'))
        if '--draft=false' in body or 'draft: false' in body:
            others.append(f)
ok['sole_publisher'] = not others
print(" ".join(f"{k}={'yes' if v else 'no'}" for k, v in ok.items()), "others=" + (",".join(others) or "-"))
PY
)"
    if [[ "$S4" != *"=no"* ]]; then
        pass "S4 release-publish.yml is the only publisher; no build/upload/delete; every check precedes the flip"
    else
        fail "S4 publisher gate invalid: $S4"
    fi
fi

# ---- S5 · the container image is retired: nothing publishes an image ---------------
# v1.234.0 (owner): the GHCR image is retired (it was never a supported install path).
# No workflow may push an image to a registry. Docker stays allowed for the DEB/RPM build
# and test containers, which only pull and run.
S5="$(python3 - "$ROOT/.github/workflows" "$ROOT" <<'PY'
import sys, os
wf, root = sys.argv[1], sys.argv[2]
hits = []
for f in sorted(os.listdir(wf)):
    if not f.endswith(('.yml', '.yaml')):
        continue
    body = "\n".join(l for l in open(os.path.join(wf, f)).read().split("\n") if not l.lstrip().startswith('#'))
    for tok in ('docker push', 'docker/build-push-action', 'docker/login-action', 'ghcr.io', 'packages: write'):
        if tok in body:
            hits.append(f"{f}:{tok}")
for p in ('Dockerfile', '.github/workflows/docker.yml'):
    if os.path.exists(os.path.join(root, p)):
        hits.append(p)
print(",".join(hits) or "-")
PY
)"
if [[ "$S5" == "-" ]]; then pass "S5 no workflow builds or pushes a container image (image retired)"
else fail "S5 a container-image publisher or its inputs are back: $S5"; fi

# ---- extract the production publish step -----------------------------------------
python3 - "$WF" "$TMP/publish.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for st in d['jobs']['verify-release']['steps']:
    if 'complete the draft release' in str(st.get('name', '')):
        open(sys.argv[2], 'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
[[ -s "$TMP/publish.sh" ]] || { fail "G0 could not extract the publish step"; echo "RESULT: FAIL"; exit 1; }
pass "G0 publish logic extracted from the production workflow"
bash -n "$TMP/publish.sh" 2>/dev/null && pass "G0b extracted block is syntactically valid" \
                                      || { fail "G0b extracted block has a syntax error"; echo "RESULT: FAIL"; exit 1; }
# ⛔ NONZERO_TEST_RC != EXPECTED FAILURE PROVEN.

ABS="/tmp/release-verify"
grep -qF "$ABS" "$TMP/publish.sh" || { fail "G0c publish step no longer references $ABS — relocation would be vacuous"; echo "RESULT: FAIL"; exit 1; }
sed -i "s|${ABS}|\$PWD/dist|g; s|/tmp/published-assets.txt|\$PWD/published-assets.txt|g" "$TMP/publish.sh"
sed -i "s|rm -rf \$PWD/dist||" "$TMP/publish.sh"
pass "G0c paths relocated to the per-case sandbox"

# ---- harness: a stub `gh` whose upload set is CONTROLLABLE -------------------------
# ⛔ The stub decides only WHICH uploads land, never whether the step passes. That is
#    what lets an arm reproduce "checksummed but not published" faithfully.
mk(){
    local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d/dist" "$d/scripts/ci/data" "$d/bin"
    cp "$DECL_SRC" "$d/scripts/ci/data/slsa-subjects.tsv"
    cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
# args: release upload <ver> <file> ... | release view ... | release edit ...
case "$2" in
  upload)
    f="$4"
    # DROP_UPLOAD names an artifact the publisher "uploads" without it ever landing —
    # the v1.229.4 shape, where the upload authority did not exist at all.
    if [ -n "${DROP_UPLOAD:-}" ] && [ "$f" = "$DROP_UPLOAD" ]; then exit 0; fi
    echo "$f" >> "$PUBLISHED_SET"; exit 0 ;;
  view)
    # the draft completer asks `--json isDraft`: the release under test is a draft
    for a in "$@"; do [ "$a" = "isDraft" ] && { echo true; exit 0; }; done
    sort -u "$PUBLISHED_SET" 2>/dev/null; exit 0 ;;
  edit)   echo "PUBLISHED" > "$PWD/PUBLISHED.marker"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$d/bin/gh"
    printf '%s' "$d"
}
# seed: the assets create-release already uploaded (packages), plus the checksum rows
seed(){ # $1 dir  $2... basenames present in SHA256SUMS and on disk
    local d="$1"; shift
    : > "$d/published-set.txt"
    : > "$d/dist/SHA256SUMS"
    local f
    for f in "$@"; do
        printf 'content-%s\n' "$f" > "$d/dist/$f"
        ( cd "$d/dist" && sha256sum "$f" >> SHA256SUMS )
        # packages are already on the draft release; the two SLSA artifacts are not
        case "$f" in nftban-core-linux-amd64) : ;; *) echo "$f" >> "$d/published-set.txt" ;; esac
    done
}
run_pub(){ ( cd "$1" && PATH="$1/bin:$PATH" REF=v1.229.5 \
    GITHUB_WORKSPACE="$1" GITHUB_REPOSITORY=itcmsgr/nftban \
    PUBLISHED_SET="$1/published-set.txt" DROP_UPLOAD="${2:-}" \
    bash "$TMP/publish.sh" 2>&1 ); }
rc_pub(){ ( cd "$1" && PATH="$1/bin:$PATH" REF=v1.229.5 \
    GITHUB_WORKSPACE="$1" GITHUB_REPOSITORY=itcmsgr/nftban \
    PUBLISHED_SET="$1/published-set.txt" DROP_UPLOAD="${2:-}" \
    bash "$TMP/publish.sh" >/dev/null 2>&1 ); echo $?; }

SUBJ="$(awk -F'\t' '$1=="subject"{print $2; exit}' "$DECL_SRC")"
PROV="$(awk -F'\t' '$1=="subject"{print $3; exit}' "$DECL_SRC")"

# ---- POSITIVE · a complete release publishes --------------------------------------
d="$(mk pos)"; seed "$d" "nftban-el9-x86_64.rpm" "nftband-linux-amd64" "$SUBJ"
printf 'prov\n' > "$d/dist/$PROV"
out="$(run_pub "$d")"; rc="$(rc_pub "$d")"
# v1.234.0: a complete population completes the DRAFT and is NOT published here.
if [[ "$rc" -eq 0 ]] && [[ ! -f "$d/dist/PUBLISHED.marker" ]] && grep -qF 'DRAFT READY (NOT PUBLISHED)' <<<"$out"; then
    pass "POS a complete population uploads the declared subject and completes the DRAFT without publishing"
else
    fail "POS a complete population did not complete the draft as expected (rc=$rc published=$([[ -f "$d/dist/PUBLISHED.marker" ]] && echo yes || echo no))"; sed 's/^/          /' <<<"$out" | tail -6
fi

# ---- N1 · THE LOAD-BEARING ARM · the exact v1.229.4 shape --------------------------
# Built, verified, checksummed — and the upload does not land. Publication must NOT occur.
d="$(mk n1)"; seed "$d" "nftban-el9-x86_64.rpm" "nftband-linux-amd64" "$SUBJ"
printf 'prov\n' > "$d/dist/$PROV"
out="$(run_pub "$d" "$SUBJ")"; rc="$(rc_pub "$d" "$SUBJ")"
if [[ "$rc" -ne 0 ]] \
   && grep -qF '::error title=Published population incomplete::' <<<"$out" \
   && grep -qF "$SUBJ" <<<"$out" \
   && [[ ! -f "$d/dist/PUBLISHED.marker" ]]; then
    pass "N1 checksummed but not published -> FAIL, and the release STAYS A DRAFT"
    info "⛔ this is v1.229.4 exactly: every prior gate passed, the artifact never shipped"
else
    fail "N1 the v1.229.4 shape did not block publication (rc=$rc published=$([[ -f "$d/dist/PUBLISHED.marker" ]] && echo yes || echo no))"
    sed 's/^/          /' <<<"$out" | tail -6
fi

# ---- N2 · provenance absent from the release --------------------------------------
d="$(mk n2)"; seed "$d" "nftban-el9-x86_64.rpm" "$SUBJ"
printf 'prov\n' > "$d/dist/$PROV"
out="$(run_pub "$d" "$PROV")"; rc="$(rc_pub "$d" "$PROV")"
if [[ "$rc" -ne 0 ]] && grep -qF "$PROV" <<<"$out" && [[ ! -f "$d/dist/PUBLISHED.marker" ]]; then
    pass "N2 a subject published WITHOUT its provenance -> FAIL"
else
    fail "N2 missing provenance did not block publication (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- N3 · the publisher's own input is gone at upload time -------------------------
d="$(mk n3)"; seed "$d" "nftban-el9-x86_64.rpm" "$SUBJ"
printf 'prov\n' > "$d/dist/$PROV"; rm -f "$d/dist/$SUBJ"
out="$(run_pub "$d")"; rc="$(rc_pub "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Publisher input missing::' <<<"$out"; then
    pass "N3 a verified artifact absent at upload time -> FAIL (VERIFIED IS NOT PUBLISHED)"
else
    fail "N3 a missing publisher input did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- N4 · the declaration itself is missing ---------------------------------------
d="$(mk n4)"; seed "$d" "nftban-el9-x86_64.rpm" "$SUBJ"
printf 'prov\n' > "$d/dist/$PROV"
rm -f "$d/scripts/ci/data/slsa-subjects.tsv"
out="$(run_pub "$d")"; rc="$(rc_pub "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Publisher declaration missing::' <<<"$out"; then
    pass "N4 missing declaration -> FAIL (⛔ MISSING DECLARATION != EMPTY POPULATION)"
else
    fail "N4 a missing declaration did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

# ---- N5 · SHA256SUMS claims a file that was never on the release -------------------
# Distinct from N1: here the claim exists with no artifact anywhere, which is what a
# consumer of the published checksum file actually experiences.
d="$(mk n5)"; seed "$d" "nftban-el9-x86_64.rpm" "$SUBJ"
printf 'prov\n' > "$d/dist/$PROV"
printf '%s  ghost-linux-amd64\n' "$(printf 'x' | sha256sum | cut -d' ' -f1)" >> "$d/dist/SHA256SUMS"
out="$(run_pub "$d")"; rc="$(rc_pub "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF 'ghost-linux-amd64' <<<"$out"; then
    pass "N5 SHA256SUMS listing an unobtainable file -> FAIL (a checksum for a missing file is a false claim)"
else
    fail "N5 an unobtainable checksum entry did not block publication (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -4
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
