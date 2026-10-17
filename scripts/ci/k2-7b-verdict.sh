#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - K2 Phase 7b verdict (DEB): a master switch that became unusable
# after preinst must be refused by the installer and reach dpkg as a failed configure
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# Owner 2026-10-09: the verdict requires ALL of
#   1. dpkg --unpack exit 0 (the preinst accepted a usable switch)
#   2. installer exit 2 (NFTBAN_PACKAGE_INSTALLER_EXIT=2 in the configure log)
#   3. INSTALL_STATE=FAILED_CONFIG_INVALID
#   4. dpkg --configure exit non-zero
#   5. package state half-configured, checked explicitly (dpkg-query ${Status} 3rd word)
#   6. ruleset and boot files byte-identical before/after
# dpkg's own prose about the failed postinst is printed as a DIAGNOSTIC only. Its wording
# changes between dpkg versions (Ubuntu 26.04: "postinst maintainer script subprocess failed
# with exit status 1"), so no verdict depends on it.
#
# Inputs (environment):
#   K2_RC_UNPACK     dpkg --unpack exit status
#   K2_RC_CONFIGURE  dpkg --configure exit status
#   K2_CONFIGURE_LOG path of the dpkg --configure output
#   K2_STATE_LINE    the INSTALL_STATE= line of the install state file
#   K2_PKG_STATUS    dpkg-query -W -f='${Status} ${Version}' nftban-core
#   K2_SNAP_BEFORE   ruleset + boot files snapshot before
#   K2_SNAP_AFTER    ruleset + boot files snapshot after
# Exit: 0 = PASS (all six hold), 1 = FAIL (any absent or an input missing).
set -u

fail=0
need() {  # <condition holds: 0/1> <description>
    if [ "$1" -eq 0 ]; then echo "  [OK]      $2"; else echo "  [MISSING] $2"; fail=1; fi
}
isint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

rc_u="${K2_RC_UNPACK:-}"; rc_c="${K2_RC_CONFIGURE:-}"; log="${K2_CONFIGURE_LOG:-}"
st="${K2_STATE_LINE:-}"; pkg="${K2_PKG_STATUS:-}"
before="${K2_SNAP_BEFORE-__unset__}"; after="${K2_SNAP_AFTER-__unset__}"

inst=""
[ -n "$log" ] && [ -r "$log" ] && inst=$(grep -o "NFTBAN_PACKAGE_INSTALLER_EXIT=[0-9]*" "$log" | tail -1)
# dpkg-query ${Status} = "<want> <eflag> <status>"; the status word is the third field.
pkg_state=$(printf '%s\n' "$pkg" | awk '{print $3}')

echo "K2 7b verdict:"
c=1; isint "$rc_u" && [ "$rc_u" -eq 0 ] && c=0
need "$c" "dpkg --unpack exit 0 (got '${rc_u:-unset}')"
c=1; [ "$inst" = "NFTBAN_PACKAGE_INSTALLER_EXIT=2" ] && c=0
need "$c" "installer exit 2 (got '${inst:-not printed}')"
c=1; [ "$st" = "INSTALL_STATE=FAILED_CONFIG_INVALID" ] && c=0
need "$c" "INSTALL_STATE=FAILED_CONFIG_INVALID (got '${st:-unset}')"
c=1; isint "$rc_c" && [ "$rc_c" -ne 0 ] && c=0
need "$c" "dpkg --configure exit non-zero (got '${rc_c:-unset}')"
c=1; [ "$pkg_state" = "half-configured" ] && c=0
need "$c" "package state half-configured (got '${pkg:-unset}')"
c=1; [ "$before" != "__unset__" ] && [ "$after" != "__unset__" ] && [ -n "$before" ] && [ "$before" = "$after" ] && c=0
need "$c" "ruleset and boot files byte-identical before/after"

# Diagnostic only: dpkg's sentence about the failed postinst, in either known wording.
prose=""
[ -n "$log" ] && [ -r "$log" ] && prose=$(grep -oE "post-installation script subprocess returned error exit status [0-9]+|postinst maintainer script subprocess failed with exit status [0-9]+" "$log" | tail -1)
echo "  [DIAG]    dpkg says: ${prose:-no recognised postinst-failure sentence (diagnostic only)}"

if [ "$fail" -eq 0 ]; then
    echo "[PASS] K2 7b: the installer refusal reached dpkg (half-configured); rules and boot configuration byte-identical"
    exit 0
fi
echo "[FAIL] K2 7b"
exit 1
