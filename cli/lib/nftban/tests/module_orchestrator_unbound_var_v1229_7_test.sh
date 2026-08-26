#!/usr/bin/env bash
# =============================================================================
# NFTBan - module orchestrator unbound-variable guard (v1.229.7 PR-2a)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="module_orchestrator_unbound_var_v1229_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="Executes the DDoS/PortScan orchestration entrypoints under `set -u` with every side-effecting dependency stubbed, and asserts none aborts on an unbound variable. Written because v1.229.7 PR-2 split nftban_{ddos,portscan}_enable into an apply half and a CLI half, moved `local mode` into the apply half, and left the success banner in the CLI half still referencing ${mode^^}. Both files run `set -Eeuo pipefail`, so the command aborted at the final banner AFTER persisting durable intent and AFTER restarting nftband, returning non-zero. shellcheck did not flag it (a bare `mode` is a plausible global) and the PR-2 structural guard did not either -- it asserted WHAT the functions do, never that they RUN. STATIC INSPECTION != EXECUTION."
# meta:ta.id="module_orchestrator_unbound_var_v1229_7_test"
# meta:ta.owner="firewall"
# meta:ta.module="daemon-runtime-authority"
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
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_portscan.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (stubbed; no real nft/systemctl call is made)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

echo "=== module orchestrator unbound-variable guard (v1.229.7 PR-2a) ==="

# Run ONE orchestrator in a subshell with every side effect stubbed. We assert
# only that it does not die on an unbound variable; the exit status of the
# stubbed work itself is irrelevant here.
run_orchestrator() {
    local file="$1" fn="$2" out
    out="$(
        bash --noprofile --norc -c '
            set -Eeuo pipefail
            file="$1"; fn="$2"
            # Stub every side-effecting dependency BEFORE sourcing.
            systemctl() { return 1; }          # "daemon not running" branch
            nft()       { return 0; }
            nft_ipc_apply_ruleset() { return 0; }
            nft_ipc_request()       { return 0; }
            nftban_module_set_enabled() { return 0; }
            export -f systemctl nft nft_ipc_apply_ruleset nft_ipc_request nftban_module_set_enabled
            # shellcheck disable=SC1090
            source "$file" 2>/dev/null || true
            # ⛔ REACHABILITY ASSERTION. If the source failed, the function is
            # undefined and invoking it yields "command not found" -- which is
            # NOT an unbound-variable message, so the guard would report ok for
            # a subject it never executed. An earlier revision did exactly that
            # for portscan. FUNCTION TESTED != FUNCTION REACHED.
            if [ "$(type -t "$fn" || true)" != "function" ]; then
                echo "SUBJECT_UNREACHABLE: $fn is not a function after sourcing $file" >&2
                exit 97
            fi
            # Stub the heavy halves so only the orchestration shell runs.
            eval "${fn%_enable}_apply()    { return 0; }" 2>/dev/null || true
            eval "${fn%_disable}_teardown(){ return 0; }" 2>/dev/null || true
            # ⛔ stdout is discarded; STDERR IS NOT. The unbound-variable
            # message is the signal this guard exists to see -- an earlier
            # revision sent it to /dev/null and the negative control could not
            # fire. A GUARD MUST NOT DISCARD THE SIGNAL IT TESTS FOR.
            "$fn" >/dev/null
        ' _ "$file" "$fn" 2>&1
    )" || true
    # Two failure signatures. Unreachability is a FAILURE, never a pass.
    if grep -q "SUBJECT_UNREACHABLE" <<<"$out"; then
        REACH_ERR="$(grep -m1 "SUBJECT_UNREACHABLE" <<<"$out")"
        return 2
    fi
    if grep -qi "unbound variable" <<<"$out"; then
        return 1
    fi
    return 0
}

DDOS="$ROOT/cli/lib/nftban/core/nftban_ddos.sh"
PSCAN="$ROOT/cli/lib/nftban/core/nftban_portscan.sh"

for f in "$DDOS" "$PSCAN"; do
    [[ -f "$f" ]] || fail "SUBJECT_NOT_FOUND: $f"
done
[[ $FAILURES -eq 0 ]] || { echo "::error::subjects unresolved"; exit 1; }

for spec in "$DDOS:nftban_ddos_enable"     "$DDOS:nftban_ddos_disable" \
            "$PSCAN:nftban_portscan_enable" "$PSCAN:nftban_portscan_disable"; do
    file="${spec%%:*}"; fn="${spec##*:}"
    REACH_ERR=""
    run_orchestrator "$file" "$fn" && rc=0 || rc=$?
    case "$rc" in
        0) ok   "$fn runs under set -u without an unbound variable" ;;
        2) fail "$fn NOT REACHED -- ${REACH_ERR:-subject undefined}. A guard that cannot run its subject proves nothing." ;;
        *) fail "$fn ABORTS on an unbound variable under set -u -- it would fail AFTER its side effects" ;;
    esac
done

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::module orchestrator unbound-variable guard FAILED: $FAILURES"
    exit 1
fi
echo "module orchestrator unbound-variable guard PASSED"
