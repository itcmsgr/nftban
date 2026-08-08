#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.159: nftban-geoban-refresh.service ExecCondition skip-not-fail
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="geoban_refresh_execcondition_v159_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-07"
# meta:description="Locks the v1.159 fix for BUG-GEOBAN-REFRESH-UNSHIPPED-GEOIP-DEGRADES-INSTALL. v1.156 enabled nftban-geoban-refresh.timer in coreTimers; its service runs the geoip CIDR refresh which needs the unshipped nftban-geoip helper. The service's ExecCondition only checked the geoban CONFIG, so on hosts with config present + binary absent it HARD-FAILED -> installer failed_units_postinstall_ok -> INSTALL_STATE=DEGRADED (fleet-wide). Fix adds a second ExecCondition gating on the geoip helper binary so a missing binary yields a SKIPPED (condition-not-met) unit, not a FAILED one. Asserts: (a) both ExecConditions present in the shipped unit; (b) the geoip-binary condition returns non-zero (=> systemd 'condition not met' => skipped) when no helper binary exists; (c) returns 0 when the arch-specific .real binary exists; (d) returns 0 with only the bin/nftban-geoip fallback. Hermetic: a TMPDIR stands in for /usr/lib/nftban; no systemd, no host."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed"
# meta:inventory.files="install/systemd/nftban-geoban-refresh.service,cli/lib/nftban/core/nftban_geoban.sh"
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-geoban-refresh.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="geoban_refresh_execcondition_v159_test"
# meta:ta.owner="geoban"
# meta:ta.module="geoban"
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
UNIT="$REPO_ROOT/install/systemd/nftban-geoban-refresh.service"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$UNIT" ]] || { echo "unit not found: $UNIT"; exit 1; }

echo "=== (a) both ExecConditions present in the shipped unit ==="
grep -qE '^ExecCondition=/usr/bin/test -f /etc/nftban/conf.d/geoban/main.conf' "$UNIT" \
  && ok "config-file ExecCondition present" || no "config-file ExecCondition missing"
# v1.228.7: the geoip helper was migrated into nftban-core; the skip-not-fail
# ExecCondition now gates on THAT (the retired standalone nftban-geoip binary is
# gone). The v1.159 protection is preserved by a truthful mechanism: a broken
# install lacking nftban-core skips the unit rather than failing it.
grep -qE '^ExecCondition=/bin/sh -c .*nftban-core' "$UNIT" \
  && ok "nftban-core ExecCondition present (v1.228.7 migration)" || no "nftban-core ExecCondition missing"
# Executable directives only — a comment explaining the migration may name the
# retired binary without being a live reference.
grep -vE '^[[:space:]]*#' "$UNIT" | grep -qE 'nftban-geoip' \
  && no "retired nftban-geoip still referenced in a unit directive" || ok "no retired nftban-geoip in unit directives"
# ExecStart must remain the geoip refresh (fix must not change behaviour-when-set-up)
grep -qE '^ExecStart=/usr/sbin/nftban geoip refresh$' "$UNIT" \
  && ok "ExecStart unchanged (nftban geoip refresh)" || no "ExecStart changed unexpectedly"

# Extract the geoip-binary ExecCondition payload and retarget /usr/lib/nftban -> sandbox
cond=$(grep -E "^ExecCondition=/bin/sh -c " "$UNIT" | grep nftban-core | head -1 | sed -E "s|^ExecCondition=/bin/sh -c '(.*)'$|\1|")
[[ -n "$cond" ]] || { echo "could not extract geoip ExecCondition payload"; exit 1; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
run_cond(){ local p="${cond//\/usr\/lib\/nftban/$SB}"; sh -c "$p"; }   # returns the condition rc

echo "=== (b) missing nftban-core => condition NOT met (rc 1..254 => systemd SKIPS, not fails) ==="
mkdir -p "$SB/bin"
rc=0; run_cond || rc=$?
{ [[ "$rc" -ge 1 && "$rc" -le 254 ]]; } && ok "no nftban-core -> rc=$rc (condition-not-met => unit skipped, NOT failed; preserves the v1.159 no-DEGRADE guarantee)" || no "expected rc 1..254 with no nftban-core, got $rc"

echo "=== (c) nftban-core present => condition met (rc 0 => run) ==="
printf '#!/bin/sh\nexit 0\n' > "$SB/bin/nftban-core"; chmod +x "$SB/bin/nftban-core"
rc=0; run_cond || rc=$?
[[ "$rc" -eq 0 ]] && ok "nftban-core present -> rc=0 (condition met => run; geoban refresh works via nftban-core + bash fallback)" || no "expected rc=0 with nftban-core, got $rc"

echo "=== (d) non-executable nftban-core => condition NOT met (skip) ==="
: > "$SB/bin/nftban-core"; chmod -x "$SB/bin/nftban-core" 2>/dev/null || true
rc=0; run_cond || rc=$?
{ [[ "$rc" -ge 1 && "$rc" -le 254 ]]; } && ok "non-executable nftban-core -> rc=$rc (skip)" || no "expected skip rc with non-exec nftban-core, got $rc"

echo "================================================================"
echo "geoban_refresh_execcondition_v159: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
