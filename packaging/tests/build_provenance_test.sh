#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="packaging/tests/build_provenance_test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Hermetic tests for the build-provenance / anti-stale-prebuilt guard: source-identity precedence + mismatch, full-40-hex enforcement, allowlisted bin cleanup, prebuilt-manifest parser rejections, and build_nftban.sh flag rejections. No Go build, no nft, no root."
# meta:inventory.files=""
# meta:inventory.binaries="bash, git, jq, sha256sum"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=packaging/lib/provenance.sh
source "$ROOT/packaging/lib/provenance.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
# expect_fail <desc> <cmd...>  → cmd must return non-zero
expect_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (expected failure, got success)"; else ok "$d"; fi; }
expect_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d (expected success, got failure)"; fi; }

C40="$(printf 'a%.0s' {1..40})"   # 40x 'a'
C40b="$(printf 'b%.0s' {1..40})"

echo "== full-commit validation =="
expect_ok   "40-hex accepted"            prov_is_full_commit "$C40"
expect_fail "12-hex rejected"            prov_is_full_commit "aaaaaaaaaaaa"
expect_fail "non-hex rejected"           prov_is_full_commit "zzzz"

echo "== source identity precedence =="
mk_root() { local d; d="$(mktemp -d)"; echo "1.2.3" > "$d/VERSION"; printf 'module x\n' > "$d/go.mod"; : > "$d/go.sum"; echo "$d"; }

d1="$(mk_root)"; ( cd "$d1" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm x )
expect_ok   "git-only checkout resolves"  prov_resolve_source_identity "$d1"

d2="$(mk_root)"; echo "$C40" > "$d2/SOURCE_COMMIT"
expect_ok   "SOURCE_COMMIT-only resolves" prov_resolve_source_identity "$d2"

d3="$(mk_root)"; ( cd "$d3" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm x )
gh="$(git -C "$d3" rev-parse HEAD)"; echo "$gh" > "$d3/SOURCE_COMMIT"
expect_ok   "git + matching SOURCE_COMMIT" prov_resolve_source_identity "$d3"

d4="$(mk_root)"; ( cd "$d4" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm x )
echo "$C40b" > "$d4/SOURCE_COMMIT"
expect_fail "git + MISMATCHED SOURCE_COMMIT rejected" prov_resolve_source_identity "$d4"

d5="$(mk_root)"   # no git, no SOURCE_COMMIT
expect_fail "no git + no SOURCE_COMMIT rejected"      prov_resolve_source_identity "$d5"

d6="$(mk_root)"; echo "abc123" > "$d6/SOURCE_COMMIT"  # short sha
expect_fail "short SOURCE_COMMIT rejected"            prov_resolve_source_identity "$d6"

echo "== allowlisted generated-bin cleanup =="
dc="$(mk_root)"; mkdir -p "$dc/bin"
for b in "${PROV_BINARIES[@]}"; do echo x > "$dc/bin/$b"; done
echo keep > "$dc/bin/not-a-binary"
expect_ok "clean allowlisted bins" prov_clean_generated_bins "$dc"
[[ ! -e "$dc/bin/nftband" ]] && ok "nftband removed" || bad "nftband not removed"
[[ -e "$dc/bin/not-a-binary" ]] && ok "non-allowlisted file preserved" || bad "non-allowlisted file wrongly removed"
# symlink masquerading as an allowlisted binary → refuse
ds="$(mk_root)"; mkdir -p "$ds/bin"; ln -s /etc/hostname "$ds/bin/nftband"
expect_fail "symlink allowlisted name refused" prov_clean_generated_bins "$ds"

echo "== prebuilt manifest parser rejections =="
# helper: valid base manifest + fake bindir, then mutate
mk_manifest() {  # <root> <bindir> <commit>  → writes $root/m.json
	local r="$1" bd="$2" c="$3" b first=1
	mkdir -p "$bd"
	{ printf '{\n "manifest_version": 1,\n "source_commit": "%s",\n "source_version": "1.2.3",\n "target_os": "linux",\n "target_arch": "amd64",\n "go_version": "go1.25",\n "module_lock_sha256": "%s",\n "binaries": [\n' "$c" "$(printf 0%.0s {1..64})"
	  for b in "${PROV_BINARIES[@]}"; do [[ $first -eq 1 ]] || printf ',\n'; first=0; printf '  {"name":"%s","sha256":"%s","embedded_commit":"%s"}' "$b" "$(printf 0%.0s {1..64})" "$c"; done
	  printf '\n ]\n}\n'; } > "$r/m.json"
}
if command -v jq >/dev/null 2>&1; then
	dm="$(mk_root)"; echo "$C40" > "$dm/SOURCE_COMMIT"; bd="$dm/bin"; mk_manifest "$dm" "$bd" "$C40"
	# bad JSON
	echo "{ not json" > "$dm/bad.json"
	expect_fail "invalid JSON rejected"           prov_verify_prebuilt "$dm" "$bd" "$dm/bad.json"
	# wrong manifest_version
	jq '.manifest_version=2' "$dm/m.json" > "$dm/v2.json"
	expect_fail "manifest_version!=1 rejected"    prov_verify_prebuilt "$dm" "$bd" "$dm/v2.json"
	# wrong arch
	jq '.target_arch="arm64"' "$dm/m.json" > "$dm/arch.json"
	expect_fail "wrong target_arch rejected"      prov_verify_prebuilt "$dm" "$bd" "$dm/arch.json"
	# duplicate binary name
	jq '.binaries += [.binaries[0]]' "$dm/m.json" > "$dm/dup.json"
	expect_fail "duplicate binary name rejected"  prov_verify_prebuilt "$dm" "$bd" "$dm/dup.json"
	# missing one binary
	jq '.binaries |= .[1:]' "$dm/m.json" > "$dm/miss.json"
	expect_fail "missing binary rejected"         prov_verify_prebuilt "$dm" "$bd" "$dm/miss.json"
	# extra unknown binary
	jq '.binaries += [{"name":"nftban-extra","sha256":"'"$(printf 0%.0s {1..64})"'","embedded_commit":"'"$C40"'"}]' "$dm/m.json" > "$dm/extra.json"
	expect_fail "extra binary rejected"           prov_verify_prebuilt "$dm" "$bd" "$dm/extra.json"
	# manifest commit != source identity (SOURCE_COMMIT is C40; manifest C40b)
	mk_manifest "$dm" "$bd" "$C40b"; mv "$dm/m.json" "$dm/badcommit.json"
	expect_fail "manifest commit != source identity rejected" prov_verify_prebuilt "$dm" "$bd" "$dm/badcommit.json"
else
	echo "  [SKIP] jq not present — manifest parser tests skipped"
fi

echo "== build_nftban.sh flag rejections (subprocess, fail before build) =="
BN="$ROOT/packaging/build_nftban.sh"
expect_fail "--use-prebuilt without manifest rejected"  bash "$BN" deb --use-prebuilt
expect_fail "--prebuilt-manifest without --use-prebuilt rejected" bash "$BN" deb --prebuilt-manifest /x
expect_fail "invalid build type rejected"               bash "$BN" bogustype

echo "== offline network surface (static) =="
BNF="$ROOT/packaging/build_nftban.sh"
# the only yq curl/fetch must live inside provision_yq's ONLINE branch, gated by PROV_OFFLINE
prov_body="$(awk '/^provision_yq\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$BNF")"
grep -q 'PROV_OFFLINE.*==.*"1"' <<<"$prov_body" && ok "provision_yq gates on PROV_OFFLINE" || bad "provision_yq not offline-gated"
# build_deb / create_rpm_spec must NOT curl yq directly any more
if grep -nE 'curl.*yq_linux_amd64|fetch_verified.*yq' "$BNF" | grep -qv 'provision_yq'; then
	# allow the reference inside provision_yq itself
	extra="$(grep -nE 'yq_linux_amd64' "$BNF" | grep -iE 'curl|fetch_verified' | grep -v 'mikefarah/yq/releases' || true)"
	[[ -z "$extra" ]] && ok "no direct yq curl outside provision_yq" || { bad "direct yq curl remains: $extra"; }
else
	ok "no direct yq curl outside provision_yq"
fi
# the rpm %install must install yq from the pre-staged source dir (no in-rpmbuild curl)
grep -q 'install -D -m 0755 %{_sourcedir}/yq_linux_amd64' "$BNF" && ok "rpm %install uses pre-staged yq (no rpmbuild network)" || bad "rpm %install still fetches yq"
grep -q 'provision_yq "${BUILD_DIR}/SOURCES/yq_linux_amd64"' "$BNF" && ok "build_rpm stages yq offline-aware" || bad "build_rpm does not stage yq via provision_yq"
# curl is not a hard build dep in offline mode
grep -q 'PROV_OFFLINE.*==.*"1".*|| command -v curl' "$BNF" && ok "curl optional under --offline" || bad "curl still hard-required offline"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
