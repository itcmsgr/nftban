#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.156 PR-D: read -ra <<< strict-IFS regression lock
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="read_ra_ifs_v156_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-07"
# meta:description="Locks the v1.156 PR-D fix for the genuinely-bare 'read -ra <<<' sites in nftban_portscan_classic.sh (the IP-timestamp splitter). Timestamps are space-joined (assignment \"\${current_timestamps} \${timestamp}\"), so under the CLI's strict IFS=\$'\\n\\t' (strict.sh, no space) a BARE 'read -ra' collapses the whole string into one element — same bug family as the v1.152 feeds-select fix. Proves (a) the bug condition under strict IFS; (b) the fix mechanism 'IFS=\$' \\t\\n' read -ra' splits correctly; (c) the SHIPPED file carries the IFS fix at both sites and no unfixed bare 'read -ra ts_array' remains. Hermetic: no host/nft/IPC/root."
# meta:input="cli/lib/nftban/core/nftban_portscan_classic.sh,cli/lib/nftban/lib/strict.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_classic.sh,cli/lib/nftban/lib/strict.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="read_ra_ifs_v156_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan"
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PORTSCAN="$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh"
STRICT="$REPO_ROOT/cli/lib/nftban/lib/strict.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1${2:+ — $2}"; }

echo "=== preconditions ==="
[[ -f "$PORTSCAN" ]] && ok "portscan_classic.sh present" || no "missing $PORTSCAN"
if grep -qE "^IFS=\\\$'\\\\n\\\\t'" "$STRICT"; then
  ok "strict.sh sets IFS=\$'\\\\n\\\\t' (no space) — the contaminating root condition"
else
  no "expected strict.sh IFS=\$'\\n\\t'" "$(grep -nE '^IFS=' "$STRICT" | head -1)"
fi

echo "=== bug condition vs fix mechanism, under strict IFS (space-joined timestamps) ==="
# Mirror the runtime value shape: timestamps space-joined like "1700000001 1700000002 1700000003".
( IFS=$'\n\t'; read -ra a <<< "1700000001 1700000002 1700000003"; [[ "${#a[@]}" -eq 1 ]] ) \
  && ok "bug condition reproduced: bare 'read -ra' under IFS=\$'\\\\n\\\\t' → 1 token" \
  || no "bug condition not reproduced (bare split unexpectedly produced multiple tokens)"
( IFS=$'\n\t'; IFS=$' \t\n' read -ra a <<< "1700000001 1700000002 1700000003"; [[ "${#a[@]}" -eq 3 ]] ) \
  && ok "fix mechanism: 'IFS=\$' \\\\t\\\\n' read -ra' → 3 tokens despite contaminated outer IFS" \
  || no "fix mechanism failed to split space-joined timestamps"

echo "=== the SHIPPED splitter carries the IFS fix at BOTH sites ==="
# Both timestamp splitters in portscan_classic.sh must use the explicit whitespace IFS.
fix_count=$(grep -cE "IFS=\\\$' \\\\t\\\\n' read -ra ts_array <<< \"\\\$timestamps\"" "$PORTSCAN" || true)
if [[ "$fix_count" -eq 2 ]]; then
  ok "both ts_array splitters use 'IFS=\$' \\\\t\\\\n' read -ra' (count=$fix_count)"
else
  no "expected 2 fixed ts_array splitters, found $fix_count" "$(grep -nE 'read -ra ts_array' "$PORTSCAN")"
fi
# No unfixed bare 'read -ra ts_array' may remain.
if grep -qE "^[[:space:]]*read -ra ts_array <<<" "$PORTSCAN"; then
  no "an UNFIXED bare 'read -ra ts_array' still present" "$(grep -nE '^[[:space:]]*read -ra ts_array <<<' "$PORTSCAN")"
else
  ok "no unfixed bare 'read -ra ts_array' remains"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS — read -ra timestamp splitters are strict-IFS-safe"
