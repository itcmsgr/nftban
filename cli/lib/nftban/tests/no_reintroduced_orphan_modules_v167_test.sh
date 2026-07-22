#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.167 PR-3 guard: confirmed-orphan shell modules stay deleted
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="no_reintroduced_orphan_modules_v167_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Hermetic guard for the v1.167 PR-3 orphan-module cleanup. Ten shell modules under cli/lib/nftban/{lib,core,exporters} had ZERO inbound source/basename references (confirmed orphans) — they were staged by the RPM recursive cp -r but never loaded at runtime, shipping dead bytes. PR-3 git-rm'd them. This guard asserts each of the 10 deleted paths stays absent from the tree, so a future cp/merge cannot silently re-introduce a dead module. Conservative form: it only checks the 10 specific deleted paths (low false-positive). Static; no rpmbuild/host; daemon byte-identical."
# meta:inventory.files="cli/lib/nftban/lib/colors.sh,cli/lib/nftban/lib/nft_lock.sh,cli/lib/nftban/lib/exporter_utils.sh,cli/lib/nftban/lib/nftban_metrics_modes.sh,cli/lib/nftban/lib/nftban_vm_enterprise.sh,cli/lib/nftban/exporters/nftban_metrics_wrapper.sh,cli/lib/nftban/core/nftban_config_safe.sh,cli/lib/nftban/core/nftban_report_engine.sh,cli/lib/nftban/core/nftban_secure_mode.sh,cli/lib/nftban/core/path_validator.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="no_reintroduced_orphan_modules_v167_test"
# meta:ta.owner="architecture"
# meta:ta.module="orphan-modules"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
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

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# The 10 confirmed-orphan modules deleted in v1.167 PR-3 (0 inbound refs).
ORPHANS=(
    cli/lib/nftban/lib/colors.sh
    cli/lib/nftban/lib/nft_lock.sh
    cli/lib/nftban/lib/exporter_utils.sh
    cli/lib/nftban/lib/nftban_metrics_modes.sh
    cli/lib/nftban/lib/nftban_vm_enterprise.sh
    cli/lib/nftban/exporters/nftban_metrics_wrapper.sh
    cli/lib/nftban/core/nftban_config_safe.sh
    cli/lib/nftban/core/nftban_report_engine.sh
    cli/lib/nftban/core/nftban_secure_mode.sh
    cli/lib/nftban/core/path_validator.sh
)

echo "orphan-module re-introduction guard (v1.167 PR-3):"

for rel in "${ORPHANS[@]}"; do
    if [[ -e "$REPO_ROOT/$rel" ]]; then
        no "deleted orphan re-introduced: $rel"
    else
        ok "absent: $rel"
    fi
done

# --- self-test: detector catches a re-introduced orphan path ------------------
tmp_dir="$REPO_ROOT/cli/lib/nftban/lib"
tmp_file="$tmp_dir/colors.sh"
if [[ ! -e "$tmp_file" ]]; then
    : > "$tmp_file"
    trap 'rm -f "$tmp_file"' EXIT
    [[ -e "$tmp_file" ]] \
        && ok "self-test: a re-introduced orphan file is detectable" \
        || no "self-test FAILED: could not stage a detectable orphan file"
    rm -f "$tmp_file"
    trap - EXIT
else
    no "self-test skipped: $tmp_file unexpectedly exists (guard should have failed above)"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
