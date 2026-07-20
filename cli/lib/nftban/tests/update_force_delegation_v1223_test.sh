#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.223.0 verdict-truth: update-force delegation (no shell verdict logic)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="update_force_delegation_v1223_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-20"
# meta:description="v1.223.0 verdict-truth (RULING 2): the `nftban update force` branch must DELEGATE to the established Go installer entry point (which runs the corrected repair/resume/validate path → shared ResolveHealthResourceVerdict) and must contain NO health-resource / MemoryMax / OOM-tier / verdict computation of its own. Structural grep assertions: (1) the force branch delegates to _cmd_update_main; (2) the force branch body carries no verdict-computation tokens; (3) cmd_update.sh as a whole computes no health verdict; (4) cmd_update.sh references the nftban-installer binary as the verdict authority."
# meta:input="cli/lib/nftban/cli/cmd_update.sh (static source; no execution)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
UPD="$REPO/cli/lib/nftban/cli/cmd_update.sh"

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=== v1.223.0 verdict-truth: update-force delegates to the installer (no shell verdict) ==="

[[ -f "$UPD" ]] && ok "cmd_update.sh present" || no "cmd_update.sh present"

# Extract the force branch body: from the `force|--force|reinstall)` case label to
# the terminating `;;`.
awk '/force\|--force\|reinstall\)/{c=1} c{print} c&&/;;/{exit}' "$UPD" > "$SB/force.sh"
[[ -s "$SB/force.sh" ]] && ok "extracted force branch body" || no "extract force branch body"

# (1) The force branch DELEGATES to the shared update orchestrator (_cmd_update_main),
#     which drives the packaged Go installer (nftban-installer) → the corrected
#     repair/resume/validate verdict path.
if grep -q "_cmd_update_main" "$SB/force.sh"; then
  ok "force branch delegates to _cmd_update_main (installer-driven path)"
else
  no "force branch must delegate to _cmd_update_main"
fi

# (2) The force branch body must contain NO health-verdict / OOM-tier / MemoryMax
#     computation of its own.
FORBIDDEN='MemoryMax=|MemoryHigh=|ClassifyEffective|HealthServiceMemoryLimits|FALLBACK_UNDERSIZED|ACTIVE_MATCH|health_resource_policy|ResolveHealthResource'
if grep -Eq "$FORBIDDEN" "$SB/force.sh"; then
  no "force branch must NOT compute a health verdict (found: $(grep -Eo "$FORBIDDEN" "$SB/force.sh" | tr '\n' ' '))"
else
  ok "force branch contains no health-verdict computation"
fi

# (3) The WHOLE cmd_update.sh computes no health verdict of its own (the verdict
#     authority is the Go installer, shared ResolveHealthResourceVerdict).
if grep -Eq "$FORBIDDEN" "$UPD"; then
  no "cmd_update.sh must NOT compute a health verdict (found: $(grep -Eno "$FORBIDDEN" "$UPD" | tr '\n' ' '))"
else
  ok "cmd_update.sh contains no health-verdict computation anywhere"
fi

# (4) cmd_update.sh references the nftban-installer binary — the delegation target
#     that owns the verdict authority.
if grep -q "nftban-installer" "$UPD"; then
  ok "cmd_update.sh references nftban-installer (delegation target / verdict authority)"
else
  no "cmd_update.sh must reference nftban-installer as the delegation target"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
