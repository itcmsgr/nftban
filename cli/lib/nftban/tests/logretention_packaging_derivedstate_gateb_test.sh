#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.222.0 — Z2 packaging derived-state + conffile parity guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logretention_packaging_derivedstate_gateb_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Z2 zero-debt guard for the log-retention packaging model. Asserts the ACTIVE /etc/logrotate.d/nftban is DERIVED STATE (never installed into the RPM buildroot or DEB payload; declared %ghost in RPM %files) so neither rpm -V nor dpkg --verify report it 'modified' — the class of verification noise the audit rejects. Also asserts operator-config PARITY: /etc/nftban/conf.d/logs.conf is a DEB conffile (matching RPM's %config(noreplace) conf.d/*.conf glob) so operator edits survive upgrades on BOTH package formats. Finally asserts the durable template baseline is shipped and both scriptlets fail-safe by copying it when generation fails. Static analysis of packaging/build_nftban.sh + packaging/deb/postinst — no package build required."
# meta:input="packaging/build_nftban.sh, packaging/deb/postinst"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="packaging/build_nftban.sh,packaging/deb/postinst"
# meta:inventory.binaries="grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/logrotate.d/nftban,/etc/nftban/conf.d/logs.conf,/etc/nftban/templates/nftban.logrotate"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (reads repo files)"
# =============================================================================
set -Eeuo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

# Resolve repo root from this test's location.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here"
while [ "$root" != "/" ] && [ ! -f "$root/packaging/build_nftban.sh" ]; do root="$(dirname "$root")"; done
SPEC="$root/packaging/build_nftban.sh"
POSTINST="$root/packaging/deb/postinst"
[ -f "$SPEC" ] || { echo "FAIL: cannot locate packaging/build_nftban.sh"; exit 1; }
[ -f "$POSTINST" ] || { echo "FAIL: cannot locate packaging/deb/postinst"; exit 1; }

echo "== derived-state: active policy never shipped into a payload =="
if grep -Eq 'buildroot\}/etc/logrotate\.d/nftban($|[^-])' "$SPEC"; then
    no "RPM installs /etc/logrotate.d/nftban into the buildroot (must be %ghost/generated)"
else
    ok "RPM does not install /etc/logrotate.d/nftban into the payload"
fi
if grep -Eq 'deb_root\}/etc/logrotate\.d/nftban"' "$SPEC"; then
    no "DEB installs /etc/logrotate.d/nftban into the payload (must be postinst-generated)"
else
    ok "DEB does not install /etc/logrotate.d/nftban into the payload"
fi

echo "== derived-state: RPM %files declares it %ghost =="
if grep -Eq '^%ghost[[:space:]].*/etc/logrotate\.d/nftban[[:space:]]*$' "$SPEC"; then
    ok "RPM %files: %ghost /etc/logrotate.d/nftban"
else
    no "RPM %files must declare %ghost /etc/logrotate.d/nftban"
fi
if grep -Eq '^/etc/logrotate\.d/nftban[[:space:]]*$' "$SPEC"; then
    no "RPM %files still has a plain (tracked) /etc/logrotate.d/nftban entry"
else
    ok "RPM %files has no plain tracked entry for the generated policy"
fi

echo "== durable template baseline still shipped (fail-safe source) =="
if grep -q 'templates/nftban.logrotate' "$SPEC"; then
    ok "template baseline /etc/nftban/templates/nftban.logrotate is packaged"
else
    no "template baseline is not packaged (fail-safe source missing)"
fi

echo "== conffile parity: logs.conf preserved on upgrade (DEB + RPM) =="
if grep -Eq '^/etc/nftban/conf\.d/logs\.conf[[:space:]]*$' "$SPEC"; then
    ok "DEB conffiles includes /etc/nftban/conf.d/logs.conf"
else
    no "DEB conffiles MUST include /etc/nftban/conf.d/logs.conf (operator edits would be lost on upgrade)"
fi
# RPM parity: the conf.d/*.conf glob is %config(noreplace), which covers logs.conf.
if grep -Eq '%config\(noreplace\)[[:space:]]+/etc/nftban/conf\.d/\*\.conf' "$SPEC"; then
    ok "RPM %config(noreplace) conf.d/*.conf glob covers logs.conf"
else
    no "RPM must mark conf.d/*.conf as %config(noreplace) (logs.conf parity)"
fi

echo "== both scriptlets fail-safe to the template on generation failure =="
if grep -q 'cp -f /etc/nftban/templates/nftban.logrotate /etc/logrotate.d/nftban' "$SPEC"; then
    ok "RPM %post copies the template baseline as a fail-safe"
else
    no "RPM %post must copy the template baseline when generation fails"
fi
if grep -q 'cp -f /etc/nftban/templates/nftban.logrotate /etc/logrotate.d/nftban' "$POSTINST"; then
    ok "DEB postinst copies the template baseline as a fail-safe"
else
    no "DEB postinst must copy the template baseline when generation fails"
fi

echo
echo "======================================================================"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
