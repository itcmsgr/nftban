#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.145 - PR-C2 apply-path hardening tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v145_pr_c2_apply_hardening_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Tests for v1.145 PR-C2 apply-path hardening: the live (never-cached) readiness helper nftban_ssh_apply_state (ready/no-table/no-sets) and the post-apply verifier nftban_ssh_port_in_both_sets, plus static assertions that maintenance/health advance state/config only on verified kernel success and no longer gate SSH-port apply on the once-cached _nft_table_available."
# meta:input="None (mocks nft)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v145_pr_c2_apply_hardening_test"
# meta:ta.owner="firewall"
# meta:ta.module="ssh-port-apply"
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
# shellcheck source=/dev/null
source "$REPO_ROOT/cli/lib/nftban/lib/ssh_port_detect.sh"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# Mock nft. MODE controls table/set presence; TCP_ELEMS/SSH_ELEMS the contents.
MODE="ready"; TCP_ELEMS="22, 80, 443"; SSH_ELEMS="22"
nft() {
    local a="$*"
    case "$a" in
        "list table ip nftban")
            [[ "$MODE" == "no-table" ]] && return 1; return 0 ;;
        "list set ip nftban tcp_ports_in")
            [[ "$MODE" == "no-table" ]] && return 1
            echo "set tcp_ports_in { elements = { $TCP_ELEMS } }"; return 0 ;;
        "list set ip nftban ssh_ports")
            { [[ "$MODE" == "no-table" || "$MODE" == "no-sets" ]]; } && return 1
            echo "set ssh_ports { elements = { $SSH_ELEMS } }"; return 0 ;;
        *) return 0 ;;
    esac
}

eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1')"; fi; }

echo "== nftban_ssh_apply_state =="
MODE=ready;    eq "$(nftban_ssh_apply_state 'ip nftban')" "ready"    "ready when table+both sets present"
MODE=no-table; eq "$(nftban_ssh_apply_state 'ip nftban')" "no-table" "no-table when table absent"
MODE=no-sets;  eq "$(nftban_ssh_apply_state 'ip nftban')" "no-sets"  "no-sets when ssh_ports missing"

echo "== nftban_ssh_port_in_both_sets =="
MODE=ready; TCP_ELEMS="22, 80, 443"; SSH_ELEMS="22"
if nftban_ssh_port_in_both_sets "ip nftban" 22; then ok "22 in BOTH sets -> verified"; else bad "22 both"; fi
TCP_ELEMS="55000, 80, 443"; SSH_ELEMS="22"   # 55000 only in tcp, not ssh_ports
if nftban_ssh_port_in_both_sets "ip nftban" 55000; then bad "55000 only-in-tcp wrongly verified"; else ok "55000 only-in-tcp -> NOT verified"; fi
TCP_ELEMS="22, 80, 443"; SSH_ELEMS="55000"   # 55000 only in ssh_ports, not tcp
if nftban_ssh_port_in_both_sets "ip nftban" 55000; then bad "55000 only-in-ssh wrongly verified"; else ok "55000 only-in-ssh -> NOT verified"; fi

echo "== static: verified-commit gating in maintenance/health =="
M="$REPO_ROOT/cli/lib/nftban/cron/maintenance.sh"
H="$REPO_ROOT/cli/lib/nftban/core/nftban_health_checks_security.sh"
has() { if grep -q "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
has "$M" 'nftban_ssh_apply_state' "maintenance uses live nftban_ssh_apply_state"
has "$M" 'nftban_ssh_port_in_both_sets' "maintenance verifies both sets"
if grep -q '_kernel_applied' "$M" && grep -q 'kernel apply unverified' "$M"; then ok "maintenance gates active-state on _kernel_applied"; else bad "maintenance state-gate"; fi
has "$H" 'nftban_ssh_apply_state' "health uses live nftban_ssh_apply_state"
has "$H" 'nftban_ssh_port_in_both_sets' "health verifies both sets via kernel (not the add return code)"
# the SSH-port apply blocks must no longer gate on the once-cached value
if grep -nE '_nft_table_available == "true"' "$M" | grep -q .; then bad "maintenance still has _nft_table_available gate in an apply block"; else ok "maintenance: no _nft_table_available gate on SSH apply blocks"; fi

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
