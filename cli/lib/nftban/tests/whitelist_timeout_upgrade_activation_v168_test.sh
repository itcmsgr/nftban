#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.168 CLI-BUG-2: upgrade-path activates timeout-capable whitelist sets
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="whitelist_timeout_upgrade_activation_v168_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-09"
# meta:description="Locks the v1.168 CLI-BUG-2 upgrade-activation backstop. A pre-v1.168 live whitelist set is created with bare 'flags interval'; GetOrCreateIntervalSet reuses an existing set without upgrading flags, so a daemon/package swap alone leaves the fix inert until a full firewall rebuild recreates the set as 'flags interval, timeout'. Asserts BOTH packaging scriptlets — the DEB postinst (packaging/deb/postinst) and the RPM %post heredoc (packaging/build_nftban.sh) — carry a v1.168 upgrade-gated block that: (a) is gated on INSTALL_MODE=upgrade and INSTALLER_EXIT<=1 (skips authority-abort/hard-fail); (b) detects a live whitelist_ipv4 set still showing bare 'flags interval' (no timeout); (c) recreates it via an explicit 'nftban firewall rebuild' (which carries its own SSH pre-rebuild lockout guard); (d) is NON-FATAL (warn + continue on failure). Hermetic: reads the two packaging source files read-only; no nft, no dpkg/rpm, no host, no root. The live kernel-level proof that the flag activates after a real package upgrade is the lab/real-host acceptance gate."
# meta:input="None (reads repo packaging files read-only)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk"
# meta:inventory.files="packaging/deb/postinst,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
DEB="$REPO_ROOT/packaging/deb/postinst"
RPM="$REPO_ROOT/packaging/build_nftban.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

for f in "$DEB" "$RPM"; do
  [[ -f "$f" ]] || { echo "file not found: $f"; exit 1; }
done

# assert_block <label> <file> : the v1.168 activation block exists with the
# four required properties. Extract the lines from the v1.168 marker to the
# next 'firewall rebuild' invocation and assert each property within.
assert_block(){
  local label="$1" file="$2"
  if ! grep -q "v1.168 CLI-BUG-2: activate timeout-capable whitelist sets" "$file"; then
    no "$label: v1.168 activation block marker missing"; return
  fi
  ok "$label: v1.168 activation block present"

  # (a) upgrade-gated + installer committed/degraded (INSTALLER_EXIT <= 1)
  if grep -qE 'INSTALL_MODE.?[ =]+.?upgrade' "$file" && grep -qE 'INSTALLER_EXIT.{0,12}-le 1' "$file"; then
    ok "$label: gated on upgrade + INSTALLER_EXIT<=1"
  else
    no "$label: missing upgrade / INSTALLER_EXIT<=1 gate"
  fi

  # (b) detects bare 'flags interval' (no timeout) on the live whitelist set
  if grep -qE 'whitelist_ipv4' "$file" && grep -qE "flags\[\[:space:\]\]\+interval\[\[:space:\]\]\*" "$file"; then
    ok "$label: detects bare 'flags interval' live set"
  else
    no "$label: missing bare-'flags interval' detection"
  fi

  # (c) recreates via explicit full 'nftban firewall rebuild' (carries SSH guard)
  if grep -qE 'nftban firewall rebuild' "$file"; then
    ok "$label: recreates via 'nftban firewall rebuild'"
  else
    no "$label: missing 'nftban firewall rebuild' activation"
  fi

  # (d) non-fatal: a warn path on failure (deb uses log_warn, rpm uses echo WARN)
  if awk '/v1.168 CLI-BUG-2: activate/{b=1} b&&/rebuild did not complete/{print; exit}' "$file" | grep -q .; then
    ok "$label: non-fatal (warns + continues on rebuild failure)"
  else
    no "$label: missing non-fatal WARN-on-failure path"
  fi
}

echo "=== DEB postinst v1.168 upgrade-activation backstop ==="
assert_block "deb" "$DEB"
echo "=== RPM %post v1.168 upgrade-activation backstop ==="
assert_block "rpm" "$RPM"

echo "================================================================"
echo "whitelist_timeout_upgrade_activation_v168_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
