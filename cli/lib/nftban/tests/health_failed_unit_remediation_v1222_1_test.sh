#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="health_failed_unit_remediation_v1222_1_test.sh"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.222.1 Lane 4 structural guard: the installer + update DEGRADED remediation render the ACTUAL failed unit from STRUCTURED install_state (SERVICES_FAILED), with NO hardcoded nftban-botscan.service generic remediation; only injection-safe canonical nftban unit names reach commands; and the EXISTING botscan/alert@ stale-clearable-oneshot recovery allowlist is preserved (unchanged behavior)."
# meta:inventory.files="cmd/nftban-installer/main.go,cmd/nftban-installer/failed_unit_remediation.go,internal/installer/validate/systemd_payload.go,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="health_failed_unit_remediation_v1222_1_test"
# meta:ta.owner="installer"
# meta:ta.module="installer"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
GO_MAIN="$ROOT/cmd/nftban-installer/main.go"
GO_REMED="$ROOT/cmd/nftban-installer/failed_unit_remediation.go"
SH_UPDATE="$ROOT/cli/lib/nftban/cli/cmd_update.sh"
GO_PAYLOAD="$ROOT/internal/installer/validate/systemd_payload.go"
fail=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1"; fail=1; }

# 1. No hardcoded generic botscan remediation in the installer DEGRADED path.
if grep -q "reset-failed nftban-botscan.service" "$GO_MAIN" "$GO_REMED"; then
    bad "Go installer still contains hardcoded 'reset-failed nftban-botscan.service'"
else
    ok "Go installer generic remediation has no hardcoded botscan"
fi
# 2. No hardcoded generic botscan remediation in the update summary.
if grep -q "reset-failed nftban-botscan.service" "$SH_UPDATE"; then
    bad "cmd_update.sh still contains hardcoded 'reset-failed nftban-botscan.service'"
else
    ok "cmd_update.sh generic remediation has no hardcoded botscan"
fi
# 3. Both renderers consume the STRUCTURED SERVICES_FAILED.
grep -q "ServicesFailed" "$GO_REMED" && ok "Go renderer consumes structured ServicesFailed" || bad "Go renderer not structured"
grep -qF 'SERVICES_FAILED=' "$SH_UPDATE" && ok "shell renderer reads SERVICES_FAILED" || bad "shell renderer not structured"
# 4. Injection safety: Go renderer gates on SafeNftbanUnitName; shell gates on a canonical regex.
grep -q "SafeNftbanUnitName" "$GO_REMED" && ok "Go renderer injection-safe (SafeNftbanUnitName)" || bad "Go renderer not injection-guarded"
grep -qE 'nftband\?\[A-Za-z0-9@\._-\]\*\\.\(service\|timer' "$SH_UPDATE" && ok "shell renderer canonical-unit regex guard" || bad "shell renderer missing unit regex guard"
# 5. EXISTING botscan + alert@ stale-clearable recovery preserved (unchanged).
grep -q '"nftban-botscan": true' "$GO_PAYLOAD" && ok "existing botscan stale-clearable recovery preserved" || bad "botscan recovery allowlist changed"
grep -q '"nftban-alert@": true' "$GO_PAYLOAD" && ok "existing alert@ stale-clearable recovery preserved" || bad "alert@ recovery allowlist changed"

[ "$fail" -eq 0 ] && { echo "ALL PASS: Lane 4 failed-unit remediation guard"; exit 0; } || { echo "GUARD FAILED"; exit 1; }
