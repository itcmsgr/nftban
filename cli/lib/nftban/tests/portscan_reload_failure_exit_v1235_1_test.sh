#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235.1 - `nftban portscan reload` must not report a failed apply as success
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_reload_failure_exit_v1235_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-14"
# meta:description="v1.235.0 (lab4 reproduction of the monitor upgrade failure): the classic apply was refused, nftban_portscan_reconcile returned 1, and `nftban portscan reload` still printed 'Port scan detection reloaded successfully' and exited 0, so the firewall rebuild classified portscan as OK and only the post-validator caught the missing chains. The router calls nftban_cmd_portscan in an || context (errexit suspended), so the bare reconcile call fell through. The REAL cli/cmd_portscan.sh is driven with a stub core module: R1 a failed reconcile makes reload exit with the reconcile rc, print no success line, and name the mode whose rules were not applied; R2 restart (same branch) likewise; R3 a distinct rc (7) is propagated unchanged; R4 control: a successful reconcile still exits 0 with the success line."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_portscan.sh"
# meta:inventory.binaries="bash,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_LOG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_reload_failure_exit_v1235_1_test"
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
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../cli/cmd_portscan.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== portscan reload failure exit (v1.235.1) ==="
[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/lib/core" "$SB/log"
# Stub core module: the reconcile outcome is chosen by STUB_RC; nothing else is touched.
cat > "$SB/lib/core/nftban_portscan.sh" <<'EOF'
nftban_portscan_reconcile() {
    NFTBAN_PLAN_EFFECTIVE_MODE=classic
    echo "ERROR: refused: stub apply outcome rc=${STUB_RC}" >&2
    return "${STUB_RC}"
}
EOF

# run <rc> <action>: the REAL command function, called in an || context like the router.
run() {
    STUB_RC="$1" NFTBAN_LIB_DIR="$SB/lib" NFTBAN_LOG_DIR="$SB/log" bash -c '
        source "$1" >/dev/null 2>&1 || { echo "SOURCE_FAILED"; exit 99; }
        rc=0; nftban_cmd_portscan "$2" || rc=$?
        echo "RC=$rc"' _ "$SUBJECT" "$2" 2>&1
}

out="$(run 1 reload)"
if [[ "$out" == *"RC=1"* && "$out" != *"reloaded successfully"* && "$out" == *"NOT applied"* && "$out" == *"'classic'"* ]]; then
    pass "R1 reload: failed reconcile -> rc 1, no success line, names mode 'classic' as NOT applied"
else
    fail "R1 reload with failed reconcile: '${out//$'\n'/ | }'"
fi

out="$(run 1 restart)"
[[ "$out" == *"RC=1"* && "$out" != *"reloaded successfully"* ]] && pass "R2 restart: failed reconcile -> rc 1, no success line" \
                                                               || fail "R2 restart: '${out//$'\n'/ | }'"

out="$(run 7 reload)"
[[ "$out" == *"RC=7"* ]] && pass "R3 reload propagates the reconcile rc unchanged (7)" \
                         || fail "R3 rc not propagated: '${out//$'\n'/ | }'"

out="$(run 0 reload)"
[[ "$out" == *"RC=0"* && "$out" == *"reloaded successfully"* && "$out" != *"NOT applied"* ]] \
    && pass "R4 control: successful reconcile -> rc 0 with the success line" \
    || fail "R4 control: '${out//$'\n'/ | }'"

echo ""
[[ "$FAIL" -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
