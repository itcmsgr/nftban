#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.2 TRACK B — CONFIG RELOAD OPERATOR TRUTHFULNESS (CLI surface)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="config-reload-truthfulness-v1229-2-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-15"
# meta:description="Proves nftban config reload never reports an IPC reload as complete success. An IPC reload refreshes the daemon's singleton configuration view only; it does not reconfigure running components. The CLI must render the daemon's own restart_may_be_required signal instead of asserting success."
# meta:inventory.files="cli/lib/nftban/cli/cmd_config.sh"
# meta:inventory.privileges="none"
# meta:ta.id="config_reload_truthfulness_v1229_2_test"
# meta:ta.owner="cli"
# meta:ta.module="cli"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
# PROVEN DEFECT THIS GUARDS (lab4, 2026-08-15):
#   NFTBAN_API_ADDR was changed from 127.0.0.1:9580 to :9581 and the daemon was
#   reloaded. The daemon logged success and the config hash changed, but `ss`
#   showed the listener still on 9580. A restart with the same file moved it to
#   9581 — so the value was valid and live, and only the reporting was false.
#
#   reloadConfig references no module, listener, timer or the registry. It
#   refreshes the singleton configuration view and nothing else.
#
# INVERSION C target: restoring an unconditional "[RELOADED via IPC]" success
# line must fail this test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../cli/cmd_config.sh"

FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

echo "=== config reload truthfulness (v1.229.2 TRACK B) ==="

# --- subject must exist; absence is a test failure, never a silent pass ------
if [[ ! -f "$SUBJECT" ]]; then
    echo "  SUBJECT_NOT_FOUND: $SUBJECT"
    exit 1
fi
pass "subject located: cmd_config.sh"

# --- 1. the unconditional success line must be gone -------------------------
# The historical line printed complete success for any IPC reload.
if grep -qE '^\s*echo "\[RELOADED via IPC\]"' "$SUBJECT"; then
    fail "unconditional [RELOADED via IPC] success line is present"
else
    pass "no unconditional [RELOADED via IPC] success line"
fi

# --- 2. the CLI must consume the daemon's restart signal --------------------
if grep -q '_config_reload_restart_may_be_required' "$SUBJECT"; then
    pass "CLI consumes the daemon restart_may_be_required signal"
else
    fail "CLI does not consume restart_may_be_required — it cannot be truthful"
fi

# --- 3. that helper must actually read the daemon response ------------------
# Guard the SUBJECT of the check, not merely the helper's name: it must test the
# captured IPC payload, otherwise it could return a constant and still "pass".
helper_body="$(awk '/^_config_reload_restart_may_be_required\(\)/,/^}/' "$SUBJECT")"
if [[ -z "$helper_body" ]]; then
    fail "SUBJECT_NOT_FOUND: _config_reload_restart_may_be_required not defined"
elif grep -q '_CONFIG_LAST_RELOAD_RESPONSE' <<<"$helper_body" &&
     grep -q 'restart_may_be_required' <<<"$helper_body"; then
    pass "restart signal is derived from the captured IPC response"
else
    fail "restart signal is not derived from the IPC response (constant/unbound)"
fi

# --- 4. the response must actually be captured ------------------------------
ipc_body="$(awk '/^_config_ipc_reload\(\)/,/^}/' "$SUBJECT")"
if [[ -z "$ipc_body" ]]; then
    fail "SUBJECT_NOT_FOUND: _config_ipc_reload not defined"
elif grep -q '_CONFIG_LAST_RELOAD_RESPONSE=' <<<"$ipc_body"; then
    pass "_config_ipc_reload captures the response payload"
else
    fail "_config_ipc_reload discards the response — restart signal unobservable"
fi

# --- 5. no surface may claim a reload reconfigured running components -------
# "verified via IPC" described the transport and read as an effect claim.
if grep -qE 'Reloaded: \$reloaded \(verified via IPC\)' "$SUBJECT"; then
    fail "summary still claims 'verified via IPC' as an effect"
else
    pass "summary makes no unqualified effect claim"
fi

# --- 6. falsifiability: the patterns must match what they forbid ------------
# Without this, a typo'd pattern would make every arm above pass vacuously.
probe='        echo "[RELOADED via IPC]"'
if grep -qE '^\s*echo "\[RELOADED via IPC\]"' <<<"$probe"; then
    pass "guard pattern provably matches the forbidden line"
else
    fail "guard pattern does NOT match the forbidden line — arms are vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    echo "RESULT: PASS"
    exit 0
fi
echo "RESULT: FAIL"
exit 1
