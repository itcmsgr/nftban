#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.232.0 build provenance source kind
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="build_provenance_source_v1232_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-20"
# meta:description="v1.232.0 OPEN-BUILD-PROVENANCE-VERSION-STRING-CANNOT-DISTINGUISH-POST-RELEASE-SOURCE. Published v1.231.0 was tag commit 805c6bba while origin/main was eb909b4d; VERSION read 1.231.0 on BOTH and the trees differed by two shipped product files, so the version string alone could not answer which artifact a host was running. Falsifies prov_resolve_source_kind against REAL throwaway git repositories, never a synthetic string: a commit carrying the tag for its own VERSION resolves tag:vX; a post-release commit one ahead of that tag resolves main and NOT tag:vX (the defect scenario, reproduced exactly); a tag whose name does not match VERSION, and a matching tag pointing at a DIFFERENT commit, both refuse tag provenance; detached HEAD, feature branches, and a .git-less export each resolve to their own truthful kind, and an export with no recorded ref resolves archive rather than anything release-looking. Also asserts prov_binary_embedded_source parses the --version source field and FAILS LOUD when the field is absent (a pre-v1.232.0 or uninjected binary must not read as provenance-clean). Carries the discriminating negative control: across the tag commit and the post-release commit VERSION is byte-identical, so an assertion on VERSION alone cannot tell them apart and the source kind is the only discriminator."
# meta:input="None (throwaway git repos under TMPDIR)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,git,sed,grep,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,git,sed,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="build_provenance_source_v1232_test"
# meta:ta.owner="release"
# meta:ta.module="build-provenance"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
PROV_SRC="$REPO_ROOT/packaging/lib/provenance.sh"

command -v git >/dev/null 2>&1 || { echo "NOT_EXECUTED: git unavailable" >&2; exit 2; }
[[ -r "$PROV_SRC" ]] || { echo "NOT_EXECUTED: missing $PROV_SRC" >&2; exit 2; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0; FAILED_TESTS=()
ok()  { printf "  [PASS] %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  [FAIL] %s\n         %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected '$2', got '$1'"; }

# shellcheck source=/dev/null
source "$PROV_SRC"
declare -F prov_resolve_source_kind >/dev/null 2>&1 || {
    echo "NOT_EXECUTED: prov_resolve_source_kind not found in $PROV_SRC" >&2; exit 2; }

# Build a real repo: VERSION=$2, one commit, optionally tagged.
mkrepo() {
    local d="$1" ver="$2"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "contact@nftban.com"
    git -C "$d" config user.name "NFTBan Test"
    printf '%s' "$ver" > "$d/VERSION"
    git -C "$d" add VERSION
    git -C "$d" -c commit.gpgsign=false commit -q -m "release $ver"
}
kind_of() {
    # Clear rather than assign: these are the sourced library's outputs, so an
    # empty assignment here reads as an unused variable while `unset` states the
    # intent exactly — start each resolve from no prior answer.
    unset PROV_SOURCE_COMMIT PROV_SOURCE_VERSION PROV_SOURCE_KIND
    prov_resolve_source_identity "$1" >/dev/null 2>&1 || { printf 'IDENTITY_FAILED'; return 0; }
    prov_resolve_source_kind "$1" >/dev/null 2>&1 || { printf 'KIND_FAILED'; return 0; }
    printf '%s' "$PROV_SOURCE_KIND"
}

echo ""
echo "=== A. a release tag is recognised only when it names THIS version at THIS commit ==="

R="$SANDBOX/tagged"; mkrepo "$R" "1.231.0"
git -C "$R" tag "v1.231.0"
assert_eq "$(kind_of "$R")" "tag:v1.231.0" "A1 tag matching VERSION at this commit => tag:v1.231.0"

# The defect scenario, reproduced: one commit AFTER the release.
printf 'post-release change\n' > "$R/cmd_report.sh"
git -C "$R" add cmd_report.sh
git -C "$R" -c commit.gpgsign=false commit -q -m "fix(report): post-release product change"
assert_eq "$(kind_of "$R")" "main" "A2 one commit past the tag => main, NOT the release"

R2="$SANDBOX/othertag"; mkrepo "$R2" "1.231.0"
git -C "$R2" tag "v1.230.0"
assert_eq "$(kind_of "$R2")" "main" "A3 a tag that does not name VERSION is not release provenance"

R3="$SANDBOX/movedtag"; mkrepo "$R3" "1.231.0"
git -C "$R3" tag "v1.231.0"
printf 'x\n' > "$R3/later"; git -C "$R3" add later
git -C "$R3" -c commit.gpgsign=false commit -q -m "later"
# The tag still exists but points at the EARLIER commit.
assert_eq "$(kind_of "$R3")" "main" "A4 matching tag pointing at another commit is not release provenance"

echo ""
echo "=== B. every other source states what it actually is ==="

R4="$SANDBOX/branch"; mkrepo "$R4" "1.231.0"
git -C "$R4" checkout -q -b fix/some-lane
assert_eq "$(kind_of "$R4")" "branch:fix/some-lane" "B1 feature branch names itself"

R5="$SANDBOX/detached"; mkrepo "$R5" "1.231.0"
git -C "$R5" checkout -q --detach HEAD
assert_eq "$(kind_of "$R5")" "detached" "B2 detached HEAD is detached, not main"

R6="$SANDBOX/export"; mkdir -p "$R6"
printf '1.231.0' > "$R6/VERSION"
printf '%040d' 0 > "$R6/SOURCE_COMMIT"
assert_eq "$(kind_of "$R6")" "archive" "B3 export with no recorded ref => archive, never release-looking"

printf 'tag:v1.231.0\n' > "$R6/SOURCE_REF"
assert_eq "$(kind_of "$R6")" "tag:v1.231.0" "B4 export carries the ref the archiver recorded"

printf 'main branch  x\n' > "$R6/SOURCE_REF"
got="$(kind_of "$R6")"
if [[ "$got" == *" "* ]]; then
    bad "B5 a recorded ref is sanitised of whitespace" "got '$got'"
else
    ok "B5 a recorded ref is sanitised of whitespace"
fi

echo ""
echo "=== C. the artifact reader ==="
sample="nftban-core v1.231.0 (git 805c6bba1111111111111111111111111111aaaa, build 2026-09-20T08:00:00Z, source tag:v1.231.0)"
stub="$SANDBOX/stubbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$sample" > "$stub"; chmod +x "$stub"
assert_eq "$(prov_binary_embedded_source "$stub")" "tag:v1.231.0" "C1 reads the source field from --version"

old_line="nftban-core v1.231.0 (git 805c6bba1111111111111111111111111111aaaa, build 2026-09-20T08:00:00Z)"
stub2="$SANDBOX/stubold"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$old_line" > "$stub2"; chmod +x "$stub2"
rc=0; prov_binary_embedded_source "$stub2" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "C2 a binary with no source field FAILS LOUD (never reads as provenance-clean)"
else
    bad "C2 a binary with no source field FAILS LOUD (never reads as provenance-clean)" "returned 0"
fi

echo ""
echo "=== D. NEGATIVE CONTROL: VERSION alone cannot tell the two apart ==="
# Power check. This reproduces the register's measured state: the release commit
# and the post-release commit BOTH declare the same VERSION. If VERSION could
# discriminate them, none of the arms above would be needed.
RC="$SANDBOX/control"; mkrepo "$RC" "1.231.0"
git -C "$RC" tag "v1.231.0"
tag_commit="$(git -C "$RC" rev-parse HEAD)"
tag_version="$(cat "$RC/VERSION")"
tag_kind="$(kind_of "$RC")"
printf 'post-release product change\n' > "$RC/nftban_report_email.sh"
git -C "$RC" add nftban_report_email.sh
git -C "$RC" -c commit.gpgsign=false commit -q -m "fix(report-email): truth"
main_commit="$(git -C "$RC" rev-parse HEAD)"
main_version="$(cat "$RC/VERSION")"
main_kind="$(kind_of "$RC")"

assert_eq "$main_version" "$tag_version" "D1 CONTROL: VERSION is byte-identical across the two artifacts"
if [[ "$main_commit" == "$tag_commit" ]]; then
    bad "D2 CONTROL: the two artifacts are genuinely different commits" "commits are equal; the fixture did not diverge"
else
    ok "D2 CONTROL: the two artifacts are genuinely different commits"
fi
if [[ "$main_kind" == "$tag_kind" ]]; then
    bad "D3 the source kind discriminates what VERSION cannot" "both resolved '$main_kind'"
else
    ok "D3 the source kind discriminates what VERSION cannot ($tag_kind vs $main_kind)"
fi

echo ""
echo "============================================================"
printf "Passed: %d  Failed: %d\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf "Failed tests:\n"; for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
    exit 1
fi
exit 0
