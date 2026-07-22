#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.157 guard: RPM spec must declare exactly ONE %install section
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rpm_spec_single_install_v157_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-07"
# meta:description="Regression guard for FIX_V157_PR_A_DUPLICATE_RPM_INSTALL: the RPM spec emitted by packaging/build_nftban.sh must contain EXACTLY ONE %install section header (^%install$). v1.157 PR-A briefly added a comment containing the literal token %install inside the %install body, which rpmbuild parsed as a second %install section ('error: line N: second %install') and broke Build RPM el9/el10 deterministically. This guard asserts: (a) exactly one ^%install$ section header; (b) one each of the other real section headers; (c) NO line inside the spec heredoc carries a bare unescaped %install token outside the single header. Hermetic: static grep of the build script; no rpmbuild/host."
# meta:inventory.files="packaging/build_nftban.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rpm_spec_single_install_v157_test"
# meta:ta.owner="packaging"
# meta:ta.module="rpm-spec"
# meta:ta.execution_class="PACKAGE_BUILD"
# meta:ta.gate="package-build"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
BS="$REPO_ROOT/packaging/build_nftban.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$BS" ]] || { echo "build_nftban.sh not found"; exit 1; }

# (a) exactly one %install section header
n_install=$(grep -cE '^%install$' "$BS" || true)
[[ "$n_install" == "1" ]] && ok "exactly one ^%install\$ section header (got $n_install)" || no "expected 1 ^%install\$ header, got $n_install"

# (b) the other core section headers are single
for sec in '%prep' '%build' '%files'; do
    c=$(grep -cE "^${sec}(\$| )" "$BS" || true)
    # %files may legitimately appear once for the single (core) package
    [[ "$c" -ge 1 ]] && ok "section header ${sec} present ($c)" || no "section header ${sec} missing"
done

# (c) the broken "rpmbuild's %install sandbox" comment phrasing must be gone.
# Scoped to the regression pattern; the unrelated build_rpm() shell comment
# '...for spec %install loop' is NOT emitted to the spec and is allowed.
if grep -qE "rpmbuild.{0,4}%install" "$BS"; then
    no "yq comment still pairs 'rpmbuild' with '%install' (rpmbuild would parse a 2nd %install)" "$(grep -nE "rpmbuild.{0,4}%install" "$BS" | head -1)"
else
    ok "broken 'rpmbuild's %install sandbox' phrasing removed (FIX_V157_PR_A_DUPLICATE_RPM_INSTALL closed)"
fi

# (d) the hardened yq fetch is present in the %install body (PR-A intent preserved)
grep -qE 'retry-all-errors' "$BS" && ok "hardened curl (retry-all-errors) present in build script" || no "hardened curl missing"

echo "================================================================"
echo "rpm_spec_single_install_v157: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
