#!/usr/bin/env bash
# =============================================================================
# NFTBan - geoban shell->Go migration completion (v1.228.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="geoban_migration_v1228_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="Proves the geoban shell->Go migration is complete: no code path references the RETIRED standalone nftban-geoip binary (bin/.real/nftban-geoip-*), the dead hard-fail check_binary is gone, and nftban_geoban_update no longer calls it. GeoIP lookups live in nftban-core geoip; country-set population is served by the bash implementation (nftban_geoban_fetch_bash). Before this fix nftban geoban update/ban hard-failed 'nftban-geoip binary not found' on every host post-migration (measured dns1). Static: greps source, invokes no host. Runtime bash-fetch is proven by the package-native lab gate."
# meta:ta.id="geoban_migration_v1228_7_test"
# meta:ta.owner="firewall"
# meta:ta.module="geoban-migration"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GEOBAN="$ROOT/cli/lib/nftban/core/nftban_geoban.sh"
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

[[ -f "$GEOBAN" ]] || { echo "FAIL: geoban lib missing"; exit 1; }

# Strip comments — a doc comment naming the retired path (to warn against
# reintroducing it) must neither satisfy nor violate the assertion.
CODE="$(grep -vE '^[[:space:]]*#' "$GEOBAN")"

# 1. No EXECUTABLE reference to the retired standalone binary path.
if grep -qE 'bin/\.real/nftban-geoip|bin/nftban-geoip' <<<"$CODE"; then
    no "RETIRED_BINARY_PATH_IN_CODE"; grep -nE 'bin/\.real/nftban-geoip|bin/nftban-geoip' <<<"$CODE" | head -3 | sed 's/^/       /'
else
    ok "NO_RETIRED_BINARY_PATH_IN_CODE"
fi

# 2. The dead hard-fail function is gone.
grep -q 'nftban_geoban_check_binary()' <<<"$CODE" \
    && no "DEAD_HARD_CHECK_STILL_DEFINED" || ok "DEAD_HARD_CHECK_REMOVED"

# 3. update() must not call the removed hard check (the dns1 failure).
upd="$(awk '/^nftban_geoban_update\(\)/{f=1} f{print} /^}/{if(f)exit}' "$GEOBAN")"
grep -q 'check_binary ' <<<"$upd" \
    && no "UPDATE_STILL_HARD_CHECKS" || ok "UPDATE_FALLS_THROUGH_TO_BASH"

# 4. The bash implementation that serves country population still exists.
grep -q 'nftban_geoban_fetch_bash()' <<<"$CODE" \
    && ok "BASH_FETCH_IMPLEMENTATION_PRESENT" || no "BASH_FETCH_MISSING"

# 5. GEOIP_BINARY defined (empty) so soft checks resolve to bash, not undefined.
grep -qE '^GEOIP_BINARY=""' <<<"$CODE" \
    && ok "GEOIP_BINARY_EMPTY_DEFINED" || no "GEOIP_BINARY_UNDEFINED_OR_RESOLVED"

echo "=== geoban_migration_v1228_7: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
