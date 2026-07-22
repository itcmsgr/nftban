#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.155 PR-1 socket-activated SSH port-mismatch warning
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ssh_socket_port_mismatch_v155_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Hermetic tests for nftban_ssh_socket_port_mismatch_audit (lib/ssh_admin_port_guard.sh, v1.155 PR-1 / item 3.2). Verifies the socket-activated sshd port-mismatch warning fires ONLY when configured (sshd -T) != listening (ss) AND sshd is socket-activated, prints the EXACT remediation hint 'systemctl daemon-reload && systemctl restart ssh.socket', and is silent when ports match or when sshd is a plain service (not socket-activated). Also asserts the section is surfaced through nftban_ssh_admin_port_audit. Hermetic: stubs sshd + listeners + systemctl; no host/IPC/root/nft."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sort,paste,tr"
# meta:inventory.files="cli/lib/nftban/lib/ssh_admin_port_guard.sh"
# meta:inventory.binaries="bash,grep,awk,sort,paste,tr"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="ssh.socket,sshd.socket"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="ssh_socket_port_mismatch_v155_test"
# meta:ta.owner="firewall"
# meta:ta.module="ssh-admin-port-guard"
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
GUARD="$REPO_ROOT/cli/lib/nftban/lib/ssh_admin_port_guard.sh"

# The verbatim remediation hint the warning must contain (PR-1 contract).
HINT="systemctl daemon-reload && systemctl restart ssh.socket"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
NFT_WRITE_LOG="$SANDBOX/nft_writes.log"
: > "$NFT_WRITE_LOG"

# ---- stubs --------------------------------------------------------------
# nft: read-only list returns ssh_ports={22}; ANY write is recorded + fails
# so an accidental nft write in this read-only path is caught.
nft() {
    case "$1" in
        list)
            if [[ "$*" == *"ssh_ports"* ]]; then
                echo "table ip nftban { set ssh_ports { type inet_service; elements = { 22 } } }"
            fi
            return 0 ;;
        add|delete|insert|replace|create|flush)
            echo "$*" >> "$NFT_WRITE_LOG"; return 1 ;;
        *) return 0 ;;
    esac
}
export -f nft

# sshd: stub `sshd -T` to emit a configurable `port` line; `command -v sshd` works
# because the function shadows the binary name.
SSHD_TPORT="22"
sshd() {
    if [[ "$1" == "-T" ]]; then
        local p
        for p in $SSHD_TPORT; do echo "port $p"; done
        echo "permitrootlogin no"
        return 0
    fi
    return 0
}
export -f sshd

# listeners: configurable actual sshd listener set (newline-separated).
DETECT_PORTS="22"
nftban_detect_ssh_ports() { printf '%s\n' $DETECT_PORTS; }
export -f nftban_detect_ssh_ports

# systemctl: is-active for the socket units is driven by SOCKET_ACTIVE.
SOCKET_ACTIVE=0
systemctl() {
    if [[ "$1" == "is-active" ]]; then
        case "$2" in
            ssh.socket|sshd.socket)
                if [[ "$SOCKET_ACTIVE" == "1" ]]; then echo "active"; return 0; fi
                echo "inactive"; return 3 ;;
            *) echo "inactive"; return 3 ;;
        esac
    fi
    return 0
}
export -f systemctl

# shellcheck source=/dev/null
source "$GUARD"

reset_state() {
    : > "$NFT_WRITE_LOG"
    SSHD_TPORT="22"; DETECT_PORTS="22"; SOCKET_ACTIVE=0
    unset SSH_CLIENT SSH_CONNECTION NFTBAN_EXTERNAL_ADMIN_SSH_PORTS 2>/dev/null || true
}

echo "=== helper: _nftban_sshd_configured_ports parses sshd -T port lines ==="
reset_state; SSHD_TPORT="2222"
[[ "$(_nftban_sshd_configured_ports | paste -sd, -)" == "2222" ]] \
    && ok "configured_ports: single port from sshd -T" || no "configured_ports single"
reset_state; SSHD_TPORT="22 2222"
[[ "$(_nftban_sshd_configured_ports | paste -sd, -)" == "22,2222" ]] \
    && ok "configured_ports: multi-port sorted-unique" || no "configured_ports multi"

echo "=== helper: _nftban_ssh_socket_activated reflects ssh.socket is-active ==="
reset_state; SOCKET_ACTIVE=1
_nftban_ssh_socket_activated && ok "socket_activated: true when ssh.socket active" || no "socket_activated true"
reset_state; SOCKET_ACTIVE=0
_nftban_ssh_socket_activated && no "socket_activated: false when no socket" || ok "socket_activated: false when plain sshd.service"

echo "=== WARN: socket-activated AND configured != listening ==="
reset_state; SOCKET_ACTIVE=1; SSHD_TPORT="2222"; DETECT_PORTS="22"
out="$(nftban_ssh_socket_port_mismatch_audit 2>&1)"
echo "$out" | grep -q "socket-activated sshd port mismatch" && ok "warns on socket-activated mismatch" || no "warn fires" "$out"
echo "$out" | grep -q "CONFIGURED for :2222" && ok "names configured port :2222" || no "names configured" "$out"
echo "$out" | grep -q "LISTENING on :22" && ok "names listening port :22" || no "names listening" "$out"
echo "$out" | grep -Fq "$HINT" && ok "prints EXACT remediation hint" || no "exact hint" "$out"
[[ ! -s "$NFT_WRITE_LOG" ]] && ok "no nft write (read-only)" || no "nft write" "$(cat "$NFT_WRITE_LOG")"

echo "=== NO WARN: socket-activated but configured == listening ==="
reset_state; SOCKET_ACTIVE=1; SSHD_TPORT="22"; DETECT_PORTS="22"
out="$(nftban_ssh_socket_port_mismatch_audit 2>&1)"
[[ -z "$out" ]] && ok "silent when ports match" || no "should be silent (match)" "$out"

echo "=== NO WARN: ports differ but NOT socket-activated (plain sshd.service) ==="
reset_state; SOCKET_ACTIVE=0; SSHD_TPORT="2222"; DETECT_PORTS="22"
out="$(nftban_ssh_socket_port_mismatch_audit 2>&1)"
[[ -z "$out" ]] && ok "silent when not socket-activated (plain service applies Port on reload)" || no "should be silent (plain service)" "$out"

echo "=== surfaced via nftban_ssh_admin_port_audit (text-mode) ==="
reset_state; SOCKET_ACTIVE=1; SSHD_TPORT="2222"; DETECT_PORTS="22"
out="$(nftban_ssh_admin_port_audit 2>&1)"
echo "$out" | grep -q "socket-activated sshd port mismatch" && ok "ssh-audit surfaces the mismatch section" || no "audit surfaces" "$out"
echo "$out" | grep -Fq "$HINT" && ok "ssh-audit prints the exact hint" || no "audit hint" "$out"
echo "$out" | grep -q "no external-admin-port mismatch" && ok "audit still prints its normal verdict line" || no "audit normal verdict" "$out"

echo "=== ssh-audit clean host: no socket section ==="
reset_state; SOCKET_ACTIVE=1; SSHD_TPORT="22"; DETECT_PORTS="22"
out="$(nftban_ssh_admin_port_audit 2>&1)"
echo "$out" | grep -q "socket-activated sshd port mismatch" && no "clean host: must not warn" "$out" || ok "clean host: no socket-mismatch warning"

echo ""
echo "================================================================"
echo "ssh_socket_port_mismatch_v155: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
