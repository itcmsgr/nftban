#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.145 - PR-B runtime static guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v145_pr_b_runtime_static_guard_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Static regression guard for v1.145 PR-B: asserts no scalar head -1 SSH-port detector remains in runtime enforcement paths, that each path consumes the union/primary wrapper, and that both-set (tcp_ports_in + ssh_ports) parity is present in the mutation paths (maintenance, health, cmd_port)."
# meta:input="None (greps repo source read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v145_pr_b_runtime_static_guard_test"
# meta:ta.owner="firewall"
# meta:ta.module="ssh-port-detect"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# Runtime enforcement paths that must NOT contain scalar SSH-port detection.
ENFORCE_FILES=(
    cli/lib/nftban/cron/maintenance.sh
    cli/lib/nftban/core/nftban_health_checks_security.sh
    cli/lib/nftban/cli/cmd_system.sh
    cli/lib/nftban/cli/cmd_update.sh
    cli/lib/nftban/cli/cmd_firewall.sh
)

echo "== no scalar head -1 SSH-port detector remains =="
# Patterns that indicate the old scalar detectors. The fallback parser lives
# only in lib/ssh_port_detect.sh and is intentionally excluded.
SCALAR_RE='Port[^|]*\| *awk[^|]*\| *head -1|grep -m1 -oP[^|]*Port|sshd[^|]*\| *head -1|grep -oP .sshd.*head -1'
for f in "${ENFORCE_FILES[@]}"; do
    if grep -nEq "$SCALAR_RE" "$f"; then
        bad "$f still has a scalar SSH-port detector"
        grep -nE "$SCALAR_RE" "$f" | sed 's/^/        /'
    else
        ok "$f: no scalar SSH-port detector"
    fi
done

echo "== each enforcement path consumes the wrapper =="
for f in "${ENFORCE_FILES[@]}"; do
    if grep -q "ssh_port_detect.sh" "$f" && grep -qE "nftban_detect_ssh_(ports|primary_port)" "$f"; then
        ok "$f: consumes the union/primary wrapper"
    else
        bad "$f: does not consume the wrapper"
    fi
done

echo "== both-set parity (ssh_ports updated alongside tcp_ports_in) =="
for f in cli/lib/nftban/cron/maintenance.sh cli/lib/nftban/core/nftban_health_checks_security.sh cli/lib/nftban/cli/cmd_port.sh; do
    if grep -q "ssh_ports" "$f"; then
        ok "$f: references ssh_ports (both-set parity)"
    else
        bad "$f: no ssh_ports parity"
    fi
done

echo "== SSH_CLIENT active-port remove guard preserved in cmd_port =="
if grep -q 'ACTIVE SSH port' cli/lib/nftban/cli/cmd_port.sh; then
    ok "cmd_port: SSH_CLIENT remove guard intact"
else
    bad "cmd_port: SSH_CLIENT remove guard missing"
fi

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
