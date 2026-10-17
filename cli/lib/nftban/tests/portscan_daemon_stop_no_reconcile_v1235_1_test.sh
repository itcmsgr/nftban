#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235.1 - nftband Stop() must not run the portscan reconcile
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_daemon_stop_no_reconcile_v1235_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-14"
# meta:description="v1.235.1: (*Module).Stop() in internal/portscan/module.go called disable(), which ran nftban_portscan_reconcile; gracefulShutdown (cmd/nftband/daemon_lifecycle.go) closes the IPC listener BEFORE registry.StopAll(), so on every nftband stop/restart with PortScan enabled the re-apply reached only the socket backlog, socat returned an empty response and the daemon logged 'Classic enable FAILED' (lab4 + lab2 v1.235.1 upgrades; reproduced by systemctl restart nftband). Shell-side structural arm (runs without a Go toolchain): S1 the shipped Stop() body has no call into enable/disable/a process spawn/a portscan shell literal; S2 (*Module).disable() is gone; S3 the ordering premise still holds (listener closed before StopAll), so a Stop()-time IPC call cannot succeed; S4 negative control: the walker flags the v1.235.0 Stop() body. Go twin: internal/portscan/stop_is_not_disable_v1235_1_test.go."
# meta:input="None (reads repository sources)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="internal/portscan/module.go,cmd/nftband/daemon_lifecycle.go"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_daemon_stop_no_reconcile_v1235_1_test"
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="$ROOT/internal/portscan/module.go"
LC="$ROOT/cmd/nftband/daemon_lifecycle.go"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== nftband Stop() does not reconcile portscan (v1.235.1) ==="
for f in "$MOD" "$LC"; do [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; exit 1; }; done

# body_of <file> <regex of the func line>: the function body up to its closing "}" at column 0.
# (The regex goes through ENVIRON: awk -v would eat its backslashes.)
body_of() { BODY_RE="$2" awk '$0 ~ ENVIRON["BODY_RE"] {f=1} f {print} f && /^}/ {exit}' "$1"; }
# forbidden <body>: calls/literals that can reach the shell or the enforcement plane
# (comment lines are not code).
forbidden() { local code; code="$(grep -v '^[[:space:]]*//' <<< "$1")"
    grep -nE '\.(enable|disable)\(|\b(Command|CommandContext|CombinedOutput)\(|\.(Run|Output)\(|"[^"]*nftban_portscan_' <<< "$code"; }

stop="$(body_of "$MOD" '^func \(m \*Module\) Stop\(\) error \{')"
if [[ -z "$stop" ]]; then
    fail "S1 SUBJECT_NOT_FOUND: func (m *Module) Stop() in internal/portscan/module.go"
elif hits="$(forbidden "$stop")"; then
    fail "S1 Stop() can reach the enforcement plane: ${hits//$'\n'/ | }"
else
    pass "S1 Stop() has no call into enable/disable, a process spawn or a portscan shell entry point"
fi

grep -qE '^func \(m \*Module\) disable\(' "$MOD" \
    && fail "S2 (*Module).disable() still exists (it ran nftban_portscan_reconcile)" \
    || pass "S2 (*Module).disable() is gone"

gs="$(body_of "$LC" '^func \(d \*Daemon\) gracefulShutdown\(\) \{')"
l_close=$(awk '/socketLn\.Close\(\)/{print NR; exit}' <<< "$gs")
l_stop=$(awk '/registry\.StopAll\(\)/{print NR; exit}' <<< "$gs")
[[ -n "$l_close" && -n "$l_stop" && "$l_close" -lt "$l_stop" ]] \
    && pass "S3 premise holds: gracefulShutdown closes the IPC listener (line $l_close) before StopAll (line $l_stop)" \
    || fail "S3 premise changed: listener close ${l_close:-?} vs StopAll ${l_stop:-?} -- re-evaluate this test"

pre='func (m *Module) Stop() error {
	if !m.config.Enabled {
		return nil
	}
	if m.cancel != nil {
		m.cancel()
	}

	// Disable portscan detection
	m.disable()
	return nil
}'
forbidden "$pre" >/dev/null && pass "S4 negative control: the v1.235.0 Stop() body is flagged" \
                            || fail "S4 negative control: the walker missed m.disable() in the v1.235.0 Stop() body"

echo ""
[[ "$FAIL" -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
