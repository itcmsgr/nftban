#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1a-1 GeoIP help-path correction
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_geoip_help_path_r1a1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-21"
# meta:description="Guard for R1a-1: cmd_geoip.sh / cmd_geoban.sh help text must not advertise the stale /var/cache/nftban/geoban country-IP path and must use the real runtime path /var/lib/nftban/geoip/ (authority: nftban_geoip_download.sh + Go GeoIPDir = DataDir/geoip)."
# meta:input="None (greps the two CLI help files)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIB="${REPO_ROOT}/cli/lib/nftban"
GEOIP="${LIB}/cli/cmd_geoip.sh"
GEOBAN="${LIB}/cli/cmd_geoban.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

echo "R1a-1 GeoIP help-path — guard tests"

# 1. stale country-IP cache path must be gone from both surfaces
if grep -qF '/var/cache/nftban/geoban' "$GEOIP"; then bad "cmd_geoip.sh still advertises stale /var/cache/nftban/geoban"; else ok "cmd_geoip.sh: no stale /var/cache/nftban/geoban"; fi
if grep -qF '/var/cache/nftban/geoban' "$GEOBAN"; then bad "cmd_geoban.sh still advertises stale /var/cache/nftban/geoban"; else ok "cmd_geoban.sh: no stale /var/cache/nftban/geoban"; fi

# 2. corrected surfaces reference the real runtime path
if grep -qF '/var/lib/nftban/geoip/' "$GEOIP"; then ok "cmd_geoip.sh references /var/lib/nftban/geoip/"; else bad "cmd_geoip.sh missing /var/lib/nftban/geoip/"; fi
if grep -qF '/var/lib/nftban/geoip/' "$GEOBAN"; then ok "cmd_geoban.sh references /var/lib/nftban/geoip/"; else bad "cmd_geoban.sh missing /var/lib/nftban/geoip/"; fi

# 3. the corrected "Country IP" lines specifically use the geoip dir
if grep -qE 'Country IP.*/var/lib/nftban/geoip/' "$GEOIP"; then ok "cmd_geoip.sh 'Country IPs' line uses geoip dir"; else bad "cmd_geoip.sh 'Country IPs' line not corrected"; fi
if grep -qE 'Country IP lists.*/var/lib/nftban/geoip/' "$GEOBAN"; then ok "cmd_geoban.sh 'Country IP lists' line uses geoip dir"; else bad "cmd_geoban.sh 'Country IP lists' line not corrected"; fi

# 4. authority sanity: the runtime path matches the downloader/Go target (not a new invention)
if grep -qF '${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip' "${LIB}/core/nftban_geoip_download.sh"; then ok "authority: downloader target is DataDir/geoip (matches corrected help)"; else bad "authority: downloader target unexpected — re-verify path"; fi

echo "-----------------------------------------------"
printf 'R1a-1 help-path tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
