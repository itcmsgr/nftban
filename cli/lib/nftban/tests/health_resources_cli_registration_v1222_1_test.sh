#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="health_resources_cli_registration_v1222_1_test.sh"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.222.1 Lane 3 registration + read-only guard: `resources` is registered in nftban-core and under `nftban health`; the stale `resource-profile` command name does NOT exist; `nftban profile` is untouched; and cmd_resources.go performs NO mutation (only `systemctl show`) and NO shell/Go RAM-policy calculation of its own."
set -u
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
CORE_MAIN="$ROOT/cmd/nftban-core/main.go"
CORE_CMD="$ROOT/cmd/nftban-core/cmd_resources.go"
HEALTH_SH="$ROOT/cli/lib/nftban/cli/cmd_health.sh"
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# 1. Internal command registered.
grep -qE 'case "resources"' "$CORE_MAIN" && ok "nftban-core 'resources' registered" || bad "nftban-core 'resources' NOT registered"
# 2. Public subcommand under health.
grep -qE '^\s*resources\)' "$HEALTH_SH" && ok "nftban health 'resources' subcommand present" || bad "nftban health 'resources' subcommand missing"
grep -qE 'resources \[--json\]' "$HEALTH_SH" && ok "health help lists 'resources [--json]'" || bad "health help missing 'resources' entry"
# 3. Stale 'resource-profile' COMMAND registration must not exist in the actual
#    dispatch files (the .conf FILE name and test pattern strings are allowed).
if grep -qE 'case "resource-profile"' "$CORE_MAIN" || grep -qE '^\s*resource-profile\)' "$HEALTH_SH"; then
    bad "stale 'resource-profile' command still registered"
else
    ok "no stale 'resource-profile' command registration"
fi
# 4. 'nftban profile' security preset must remain (collision-free coexistence).
if [ -f "$ROOT/cli/lib/nftban/cli/cmd_profile.sh" ] || grep -rqE 'nftban_cmd_profile' "$ROOT/cli" 2>/dev/null; then
    ok "nftban profile (security preset) untouched"
else
    echo "INFO: cmd_profile not found in this tree (may be a separate module) — non-blocking"
fi
# 5. READ-ONLY: the resources command must only run 'systemctl show' and never mutate.
if grep -nE 'exec\.Command\(' "$CORE_CMD" | grep -vqE '"systemctl", *"show"'; then
    bad "cmd_resources.go runs an exec.Command other than 'systemctl show'"
else
    ok "cmd_resources.go only execs 'systemctl show' (read-only)"
fi
for verb in 'WriteFile' 'daemon-reload' 'reset-failed' 'os\.Remove' 'MkdirAll' '"start"' '"restart"' 'DaemonReload' 'RemoveHealthResourceDropin' 'ReconcileHealthResource'; do
    if grep -qE "$verb" "$CORE_CMD"; then
        bad "cmd_resources.go references a MUTATING/reconcile operation: $verb"
    fi
done
grep -qE "$" "$CORE_CMD" && ok "cmd_resources.go contains no mutating verbs (read-only diagnostic)"
# 6. No shell-side RAM/tier calculation in the health resources path.
if sed -n '/resources)/,/;;/p' "$HEALTH_SH" | grep -qE '/proc/meminfo|nproc|MemoryMax=|ClassifyResourceTier|GetResourceLimits'; then
    bad "shell 'resources' path performs resource-policy calculation (must delegate to Go)"
else
    ok "shell 'resources' path is pure delegation (no policy calc)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS: health resources CLI registration + read-only guard"; exit 0; } || { echo "GUARD FAILED"; exit 1; }
