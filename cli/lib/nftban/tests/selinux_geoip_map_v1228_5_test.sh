#!/usr/bin/env bash
# =============================================================================
# NFTBan - SELinux GeoIP mmap grant (v1.228.5 completion)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="selinux_geoip_map_v1228_5_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-04"
# meta:description="v1.228.5 completion control for BUG-SELINUX-GEOIP-MMDB-MAP-DENIED. On a stock EL9 host with SELinux Enforcing, nftban-core-geoip.service downloaded the MaxMind database successfully and then failed at the verification step with 'permission denied', leaving a FAILED package-owned unit after an otherwise successful package transaction. Root cause: manage_files_pattern grants open/read/write but NOT map, and map is a DISTINCT SELinux permission; the GeoIP consumer memory-maps the .mmdb during verification. MEASURED denial: avc denied { map } comm=nftban-core path=/var/lib/nftban/geoip/dbip-country-lite.mmdb scontext=nftband_t tcontext=nftban_var_lib_t tclass=file permissive=0. The denial reproduces ONLY in the service domain (nftband_t); an interactive run in unconfined_t succeeds, which is why it stayed invisible until a lab ran EL9 Enforcing. This control asserts the narrow grant is present in the shipped policy source, that it is scoped to file:map on the daemon's own state type, and that the unrelated sysctl_net_t candidate was NOT smuggled in. Static - reads policy source only, no SELinux operations, no privileges."
# meta:input="install/selinux/nftban.te"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:ta.id="selinux_geoip_map_v1228_5_test"
# meta:ta.owner="security"
# meta:ta.module="selinux-geoip-map"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

TE="$(dirname "${BASH_SOURCE[0]}")/../../../../install/selinux/nftban.te"
[[ -r "$TE" ]] || { echo "cannot read $TE"; exit 1; }

grep -qE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+nftban_var_lib_t:file[[:space:]]+map;' "$TE" \
  && ok "T1 narrow grant present: allow nftband_t nftban_var_lib_t:file map;" \
  || no "T1 GeoIP map grant MISSING - the EL9 Enforcing defect is not fixed"

grep -qE 'BUG-SELINUX-GEOIP-MMDB-MAP-DENIED' "$TE" \
  && ok "T2 defect handle documented at the grant" || no "T2 rationale not documented"

grep -qE 'avc:? *denied \{ map \}|denied \{ map \}' "$TE" \
  && ok "T3 measured denial recorded in policy source" || no "T3 measured denial not recorded"

# scope: must NOT have widened to other types or added the unproven sysctl candidate
if grep -qE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+sysctl_net_t:dir[[:space:]]+search;' "$TE"; then
  no "T4 UNPROVEN sysctl_net_t:dir search grant present - impact not established, must not ship"
else
  ok "T4 unproven sysctl_net_t candidate correctly ABSENT"
fi

# file:map is an ESTABLISHED idiom here - nftban_conf_t and nftban_nftables_conf_t
# already pair manage_files_pattern with file:map. Assert the EXACT permitted set so
# scope creep is caught, rather than a count that would break on any legitimate grant.
expected="nftban_conf_t nftban_nftables_conf_t nftban_var_lib_t"
actual="$(grep -oE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+[a-z_]+:file[[:space:]]+map;' "$TE" \
          | grep -oE 'nftband_t[[:space:]]+[a-z_]+:file' | awk '{print $2}' | sed 's/:file//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
[[ "$actual" == "$expected" ]] \
  && ok "T5 file:map granted to exactly the expected types [$actual]" \
  || no "T5 file:map type set drifted - expected [$expected] got [$actual]"

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
