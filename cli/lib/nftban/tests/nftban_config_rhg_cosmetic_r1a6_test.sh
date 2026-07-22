#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1a-6 CONFIG/RHG cosmetic comment cleanup (D-RHG-1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_config_rhg_cosmetic_r1a6_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-22"
# meta:description="Guards the R1a-6 (D-RHG-1) cosmetic comment cleanup: the two conf.d header comments no longer carry the stale 'NFTBan v1.0.0' version banner, and the four scripts/ci comment blocks no longer embed the /home/commonfolder dev-machine path. Comment-only; no KEY=VALUE/default change."
# meta:input="None (greps the 6 touched files)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nftban_config_rhg_cosmetic_r1a6_test"
# meta:ta.owner="core"
# meta:ta.module="config-cosmetic-hygiene"
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

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

echo "R1a-6 CONFIG/RHG cosmetic (D-RHG-1) — guard tests"

# (1) the two conf.d headers no longer carry the stale 'NFTBan v1.0.0' banner
for c in conf.d/services.conf conf.d/login_alert.conf; do
    f="${REPO_ROOT}/cli/etc/nftban/${c}"
    if grep -qF 'NFTBan v1.0.0' "$f"; then bad "$c still has stale 'NFTBan v1.0.0' header"; else ok "$c: stale 'NFTBan v1.0.0' header removed"; fi
done

# (2) the four CI scripts no longer embed the /home/commonfolder dev-machine path
for s in test-heredoc-safety test-systemd-execstart-payload-resolution test-install-method-detection test-immutable-lifecycle-matrix; do
    f="${REPO_ROOT}/scripts/ci/${s}.sh"
    if grep -qF '/home/commonfolder' "$f"; then bad "scripts/ci/${s}.sh still embeds /home/commonfolder dev path"; else ok "scripts/ci/${s}.sh: dev-machine path removed"; fi
    # the audit scope-doc reference is preserved (cleanup, not deletion of the pointer)
    if grep -qE 'SCOPE\.md' "$f"; then ok "scripts/ci/${s}.sh: scope-doc reference preserved"; else bad "scripts/ci/${s}.sh: lost its scope-doc reference"; fi
done

echo "-----------------------------------------------"
printf 'R1a-6 cosmetic tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
