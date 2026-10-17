#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - K2 Phase 7b verdict is complete and falsifiable
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="k2_7b_verdict_falsifiability_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-09"
# meta:description="Owner 2026-10-09: the K2 Phase 7b (DEB) verdict must require installer exit 2, INSTALL_STATE=FAILED_CONFIG_INVALID, a non-zero dpkg --configure, package state half-configured (checked explicitly), unpack exit 0 and byte-identical ruleset/boot snapshots; dpkg prose is a diagnostic only (Ubuntu 26.04 reworded it and the old grep failed a correct product). Drives the REAL scripts/ci/k2-7b-verdict.sh: the complete evidence PASSES with either dpkg wording and with no recognised sentence; removing or corrupting ANY one required condition FAILS; build-packages.yml calls the script and no longer greps the old sentence. Hermetic: temp files only."
# meta:input="None"
# meta:output="PASS/FAIL per arm; exit 1 on any failure"
# meta:depends="bash,awk,grep"
# meta:inventory.files="scripts/ci/k2-7b-verdict.sh,.github/workflows/build-packages.yml"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="K2_RC_UNPACK,K2_RC_CONFIGURE,K2_CONFIGURE_LOG,K2_STATE_LINE,K2_PKG_STATUS,K2_SNAP_BEFORE,K2_SNAP_AFTER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="k2_7b_verdict_falsifiability_v1235_test"
# meta:ta.owner="packaging"
# meta:ta.module="installer"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
V="$REPO/scripts/ci/k2-7b-verdict.sh"
WF="$REPO/.github/workflows/build-packages.yml"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

[[ -f "$V" ]] || { echo "[FAIL] $V missing"; exit 1; }

# Complete, correct evidence (shape of the real ubuntu26.04 run on a3ee8b4a).
NEW="dpkg: error processing package nftban-core (--configure):
 old nftban-core package postinst maintainer script subprocess failed with exit status 1"
OLD="dpkg: error processing package nftban-core (--configure):
 installed nftban-core package post-installation script subprocess returned error exit status 1"
mklog() {  # <file> <installer line or empty> <dpkg prose or empty>
    { echo "Setting up nftban-core (1.235.0) ..."; [[ -n "$2" ]] && echo "$2"; [[ -n "$3" ]] && echo "$3"; } > "$1"
}
mklog "$WORK/good.log" "NFTBAN_PACKAGE_INSTALLER_EXIT=2" "$NEW"
SNAP="sha256 ruleset 1f2e
sha256 /etc/nftables.conf 9a8b"

run() {  # KEY=VALUE overrides on top of the complete evidence; prints rc
    env -i PATH="/usr/bin:/bin" \
        K2_RC_UNPACK=0 K2_RC_CONFIGURE=1 K2_CONFIGURE_LOG="$WORK/good.log" \
        K2_STATE_LINE="INSTALL_STATE=FAILED_CONFIG_INVALID" \
        K2_PKG_STATUS="install ok half-configured 1.235.0" \
        K2_SNAP_BEFORE="$SNAP" K2_SNAP_AFTER="$SNAP" \
        "$@" bash "$V" > "$WORK/out" 2>&1
    echo $?
}
expect() {  # <want rc> <description> [KEY=VALUE ...]
    local want="$1" d="$2"; shift 2
    local rc; rc=$(run "$@")
    if [[ "$rc" == "$want" ]]; then ok "$d (rc=$rc)"; else no "$d (rc=$rc, want $want)"; sed 's/^/        /' "$WORK/out"; fi
}

echo "=== complete evidence passes; dpkg prose does not decide ==="
expect 0 "complete evidence, Ubuntu 26.04 dpkg wording"
mklog "$WORK/old.log" "NFTBAN_PACKAGE_INSTALLER_EXIT=2" "$OLD"
expect 0 "complete evidence, older dpkg wording" K2_CONFIGURE_LOG="$WORK/old.log"
mklog "$WORK/noprose.log" "NFTBAN_PACKAGE_INSTALLER_EXIT=2" ""
expect 0 "complete evidence, no recognised dpkg sentence (diagnostic only)" K2_CONFIGURE_LOG="$WORK/noprose.log"
run >/dev/null; grep -q "\[DIAG\].*postinst maintainer script subprocess failed with exit status 1" "$WORK/out" \
    && ok "the dpkg sentence is still reported as a diagnostic" || no "the dpkg sentence is not reported"

echo "=== each required condition, when absent, fails the verdict ==="
expect 1 "unpack failed"                         K2_RC_UNPACK=1
expect 1 "unpack rc missing"                     K2_RC_UNPACK=
mklog "$WORK/inst3.log" "NFTBAN_PACKAGE_INSTALLER_EXIT=3" "$NEW"
expect 1 "installer exit 3, not 2"               K2_CONFIGURE_LOG="$WORK/inst3.log"
mklog "$WORK/noinst.log" "" "$NEW"
expect 1 "installer exit not printed"            K2_CONFIGURE_LOG="$WORK/noinst.log"
expect 1 "configure log missing"                 K2_CONFIGURE_LOG="$WORK/absent.log"
expect 1 "install state FAILED_PREFLIGHT"        K2_STATE_LINE="INSTALL_STATE=FAILED_PREFLIGHT"
expect 1 "install state missing"                 K2_STATE_LINE=
expect 1 "dpkg --configure exit 0"               K2_RC_CONFIGURE=0
expect 1 "dpkg --configure rc missing"           K2_RC_CONFIGURE=
expect 1 "package installed (not half-configured)" K2_PKG_STATUS="install ok installed 1.235.0"
expect 1 "package half-installed"                K2_PKG_STATUS="install ok half-installed 1.235.0"
expect 1 "package status unreadable"             K2_PKG_STATUS="dpkg-query: no packages found matching nftban-core"
expect 1 "package status missing"                K2_PKG_STATUS=
expect 1 "ruleset changed"                       K2_SNAP_AFTER="sha256 ruleset 0000
sha256 /etc/nftables.conf 9a8b"
expect 1 "both snapshots empty (failed snapshot)" K2_SNAP_BEFORE= K2_SNAP_AFTER=
expect 1 "after-snapshot missing"                K2_SNAP_AFTER=
# A correct-looking dpkg sentence never rescues a missing condition.
expect 1 "dpkg sentence present but configure rc 0" K2_RC_CONFIGURE=0 K2_CONFIGURE_LOG="$WORK/old.log"

echo "=== the workflow uses this verdict ==="
grep -q "bash /scripts/ci/k2-7b-verdict.sh" "$WF" && ok "build-packages.yml calls scripts/ci/k2-7b-verdict.sh" \
    || no "build-packages.yml does not call the verdict script"
grep -q 'k2_scr=$(grep -o "post-installation script subprocess' "$WF" \
    && no "build-packages.yml still makes the DEB verdict depend on the old dpkg sentence" \
    || ok "the DEB verdict no longer depends on the old dpkg sentence"

echo ""
echo "=== k2_7b_verdict_falsifiability_v1235: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
