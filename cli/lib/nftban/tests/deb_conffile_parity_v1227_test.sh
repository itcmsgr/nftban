#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.227 Lane-1 — MAIL-F8 DEB conffile parity (operator configs survive apt upgrade)
# =============================================================================
# meta:name="deb_conffile_parity_v1227_test"
# meta:type="test"
# meta:version="1.227.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="MAIL-F8: the DEB conffiles list is generated from the staged config set (parity with the RPM %config(noreplace) wildcard) instead of a drifting hand-list that omitted mail.conf/nftables.conf/stats.conf/etc. Builds a fixture staged tree from the shipped source, runs the generation logic, and asserts every operator *.conf (incl mail.conf + nftables.conf) + conf.d yaml profiles are covered while defaults/examples/.local and non-conf.d runtime templates are excluded. Static-guards that build_nftban.sh uses the generator, not the old hand-list. NOTE: package-native upgrade preservation is proven separately on lab2 DEB + lab4 RPM (EXECUTION_DEFERRED)."
# meta:input="None (reads shipped source configs + build_nftban.sh read-only; builds a temp fixture)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,find,sed,sort,grep"
# meta:inventory.files="packaging/build_nftban.sh,etc/nftban/conf.d/mail.conf,install/nftables/nftables.conf"
# meta:inventory.binaries="bash,find,sed,sort,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="deb_conffile_parity_v1227_test"
# meta:ta.owner="mail"
# meta:ta.module="deb-conffile-parity"
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck disable=SC2034  # BUILD is consumed by the assert eval expressions
BUILD="$ROOT/packaging/build_nftban.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== deb_conffile_parity_v1227 ==="

# --- build a fixture staged /etc tree from the shipped source (mirrors build_deb staging) ---
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/deb/etc/nftban/conf.d" "$FX/deb/etc/sysctl.d" "$FX/deb/etc/nftban/suricata/profiles"
cp -r "$ROOT"/etc/nftban/conf.d/* "$FX/deb/etc/nftban/conf.d/" 2>/dev/null || true
cp "$ROOT/install/nftables/nftables.conf" "$FX/deb/etc/nftban/nftables.conf"
cp "$ROOT/install/config/nftban.conf"     "$FX/deb/etc/nftban/nftban.conf"
cp "$ROOT"/etc/nftban/suricata/profiles/*.yaml "$FX/deb/etc/nftban/suricata/profiles/" 2>/dev/null || true
touch "$FX/deb/etc/sysctl.d/90-nftban.conf"
# adversarial references that MUST be excluded
touch "$FX/deb/etc/nftban/conf.d/community_stats.conf.default" \
      "$FX/deb/etc/nftban/conf.d/foo.conf.example" \
      "$FX/deb/etc/nftban/conf.d/mail.conf.local"

# --- run the generation logic (kept in lock-step with build_nftban.sh via the static guard below) ---
CONFFILES="$FX/conffiles"
{
    (
        cd "$FX/deb" || exit 0
        find etc/nftban -type f -name '*.conf' \
             ! -name '*.default' ! -name '*.example' ! -name '*.local' 2>/dev/null
        find etc/nftban/conf.d -type f \( -name '*.yaml' -o -name '*.yml' \) \
             ! -name '*.default' ! -name '*.example' ! -name '*.local' 2>/dev/null
        [ -f etc/sysctl.d/90-nftban.conf ] && echo etc/sysctl.d/90-nftban.conf
    ) | sed 's,^,/,' | LC_ALL=C sort -u
} > "$CONFFILES"

has() { grep -qxF "$1" "$CONFFILES"; }

# --- MUST be protected (the headline + the previously-drifted set) ---
assert "COVERS mail.conf (MAIL-F8 headline)"     'has "/etc/nftban/conf.d/mail.conf"'
assert "COVERS nftables.conf"                    'has "/etc/nftban/nftables.conf"'
assert "COVERS nftban.conf"                      'has "/etc/nftban/nftban.conf"'
assert "COVERS stats.conf"                       'has "/etc/nftban/conf.d/stats.conf"'
assert "COVERS login_alert.conf"                 'has "/etc/nftban/conf.d/login_alert.conf"'
assert "COVERS connectors.conf"                  'has "/etc/nftban/conf.d/connectors.conf"'
assert "COVERS a panels subdir config"           'has "/etc/nftban/conf.d/panels/plesk/main.conf"'
assert "COVERS botguard yaml profile"            'has "/etc/nftban/conf.d/botguard/profiles/generic.yaml"'
assert "COVERS sysctl drop-in"                   'has "/etc/sysctl.d/90-nftban.conf"'

# --- every shipped operator conf.d *.conf is covered (true parity, no drift) ---
missing=0
while IFS= read -r rel; do
    p="/etc/nftban/conf.d/${rel#"$FX/deb/etc/nftban/conf.d/"}"
    has "$p" || { echo "    · uncovered: $p"; missing=$((missing+1)); }
done < <(find "$FX/deb/etc/nftban/conf.d" -type f -name '*.conf' ! -name '*.default' ! -name '*.example' ! -name '*.local')
assert "EVERY shipped conf.d/*.conf is covered (0 uncovered)" '[[ "$missing" -eq 0 ]]'

# --- MUST be excluded (references + non-conf.d runtime templates) ---
assert "EXCLUDES *.conf.default"                 '! has "/etc/nftban/conf.d/community_stats.conf.default"'
assert "EXCLUDES *.conf.example"                 '! has "/etc/nftban/conf.d/foo.conf.example"'
assert "EXCLUDES *.conf.local (operator override)" '! has "/etc/nftban/conf.d/mail.conf.local"'
assert "EXCLUDES suricata runtime template yaml"  '! has "/etc/nftban/suricata/profiles/minimal.yaml"'

# coverage strictly exceeds the old 23-entry hand-list
assert "COVERAGE_EXCEEDS_OLD_HANDLIST (>23)"     '[[ "$(wc -l < "$CONFFILES")" -gt 23 ]]'

# --- static guard: build_nftban.sh GENERATES conffiles (not the old static EOF hand-list) ---
assert "BUILD uses find-generated conffiles"     'grep -q "find etc/nftban -type f -name .\\*\\.conf." "$BUILD"'
assert "BUILD writes generated list to conffiles" 'grep -q "} > \"\${BUILD_DIR}/deb/DEBIAN/conffiles\"" "$BUILD"'
assert "BUILD dropped the old hand-list heredoc"  '! grep -q "^/etc/nftban/conf.d/watchdog.conf$" "$BUILD"'

echo ""
echo "=== deb_conffile_parity_v1227: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
