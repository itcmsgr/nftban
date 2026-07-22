#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for OBS-SSHPORT-55000-FAMILY external admin SSH-port guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ssh_admin_port_guard_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Hermetic tests for the external admin SSH-port warn-only + lockout-net guard (lib/ssh_admin_port_guard.sh). Strategy WARN_ONLY_PLUS_LOCKOUT_NET. Covers: normal :22 (no warn), native :55000 listener (in-authority, no warn), external :55000->:22 redirect (mismatch warn, ssh_ports stays {22}, NO import), multi-port sshd, lockout-net via the IPC whitelist-session path only (no direct nft write), dry-run/opt-out/re-entry/no-ssh no-ops. Hermetic: stubs nft + nftban_detect_ssh_ports + _whitelist_session_add; no host/IPC/root."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sort,paste,tr"
# meta:inventory.files="cli/lib/nftban/lib/ssh_admin_port_guard.sh"
# meta:inventory.binaries="bash,grep,awk,sort,paste,tr"
# meta:inventory.env_vars="NFTBAN_EXTERNAL_ADMIN_SSH_PORTS,SSH_CLIENT,SSH_CONNECTION,NFTBAN_NO_PREREBUILD_LOCKOUT,NFTBAN_PREREBUILD_LOCKOUT_TTL"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="ssh_admin_port_guard_v150_test"
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

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
NFT_WRITE_LOG="$SANDBOX/nft_writes.log"
WL_LOG="$SANDBOX/whitelist_calls.log"
: > "$NFT_WRITE_LOG"; : > "$WL_LOG"

# ---- stubs --------------------------------------------------------------
# nft: read-only `list set` returns a fixed ssh_ports={22}; ANY write is recorded
# (and fails) so a direct-nft-write regression is caught.
nft() {
    case "$1" in
        list)
            if [[ "$*" == *"ssh_ports"* ]]; then
                echo "table ip nftban {"
                echo "  set ssh_ports {"
                echo "    type inet_service"
                echo "    elements = { 22 }"
                echo "  }"
                echo "}"
                return 0
            fi
            return 0 ;;
        add|delete|insert|replace|create|flush)
            echo "$*" >> "$NFT_WRITE_LOG"; return 1 ;;
        *) return 0 ;;
    esac
}
export -f nft

# _whitelist_session_add: the sanctioned IPC lockout-net path (recorded, never touches nft).
_whitelist_session_add() { echo "wl-add $*" >> "$WL_LOG"; return 0; }
export -f _whitelist_session_add

# nftban_detect_ssh_ports: configurable sshd listener set (newline-separated).
DETECT_PORTS="22"
nftban_detect_ssh_ports() { printf '%s\n' $DETECT_PORTS; }
export -f nftban_detect_ssh_ports

# shellcheck source=/dev/null
source "$GUARD"

reset_state() {
    : > "$NFT_WRITE_LOG"; : > "$WL_LOG"
    unset SSH_CLIENT SSH_CONNECTION NFTBAN_EXTERNAL_ADMIN_SSH_PORTS \
          NFTBAN_NO_PREREBUILD_LOCKOUT NFTBAN_PREREBUILD_LOCKOUT_TTL \
          _NFTBAN_PREREBUILD_GUARD_ACTIVE 2>/dev/null || true
    DETECT_PORTS="22"
}

echo "=== helper functions ==="
reset_state
[[ "$(NFTBAN_EXTERNAL_ADMIN_SSH_PORTS='55000, 22 80' nftban_ssh_external_admin_ports | paste -sd, -)" == "22,80,55000" ]] \
    && ok "external_admin_ports: parse+dedup+sort+validate" || no "external_admin_ports parse"
[[ -z "$(nftban_ssh_external_admin_ports)" ]] && ok "external_admin_ports: empty when unset" || no "external_admin_ports empty"
[[ "$(NFTBAN_EXTERNAL_ADMIN_SSH_PORTS='99999 abc -1' nftban_ssh_external_admin_ports)" == "" ]] \
    && ok "external_admin_ports: rejects out-of-range/non-numeric" || no "external_admin_ports range"
[[ "$(SSH_CLIENT='203.0.113.7 51000 22' nftban_ssh_active_admin_ip)" == "203.0.113.7" ]] \
    && ok "active_admin_ip: from SSH_CLIENT" || no "active_admin_ip SSH_CLIENT"
[[ "$(SSH_CONNECTION='203.0.113.7 51000 10.0.0.1 22' nftban_ssh_active_admin_ip)" == "203.0.113.7" ]] \
    && ok "active_admin_ip: from SSH_CONNECTION fallback" || no "active_admin_ip SSH_CONNECTION"
nftban_ssh_active_admin_ip >/dev/null 2>&1 && no "active_admin_ip: should fail when no ssh env" || ok "active_admin_ip: empty/fail when not in ssh"
[[ "$(SSH_CONNECTION='203.0.113.7 51000 10.0.0.1 22' nftban_ssh_active_admin_port)" == "22" ]] \
    && ok "active_admin_port: post-DNAT landed port (22) from SSH_CONNECTION" || no "active_admin_port SSH_CONNECTION"
[[ "$(SSH_CLIENT='203.0.113.7 51000 22' nftban_ssh_active_admin_port)" == "22" ]] \
    && ok "active_admin_port: landed port (22) from SSH_CLIENT 3rd field" || no "active_admin_port SSH_CLIENT"

echo "=== S1 audit: normal :22 host (clean) ==="
reset_state; DETECT_PORTS="22"
out="$(nftban_ssh_admin_port_audit 2>&1)"
echo "$out" | grep -q "ssh_ports (protected):  22" && ok "audit shows ssh_ports={22}" || no "audit ssh_ports" "$out"
echo "$out" | grep -q "no external-admin-port mismatch" && ok "audit: clean verdict, no mismatch" || no "audit clean verdict" "$out"
echo "$out" | grep -qi "is NOT an sshd listener" && no "audit: should NOT warn on clean host" || ok "audit: silent on clean host"

echo "=== S1 audit: external :55000->:22 redirect (declared, NOT a listener) ==="
reset_state; DETECT_PORTS="22"; export NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
out="$(nftban_ssh_admin_port_audit 2>&1)"
echo "$out" | grep -q "external admin port :55000 is NOT an sshd listener" && ok "audit: flags :55000 external redirect" || no "audit external flag" "$out"
echo "$out" | grep -q "will NOT import :55000 into ssh_ports" && ok "audit: states no import" || no "audit no-import statement" "$out"
echo "$out" | grep -q "ssh_ports (protected):  22" && ok "audit: ssh_ports still {22} (no import)" || no "audit ssh_ports unchanged" "$out"
[[ ! -s "$NFT_WRITE_LOG" ]] && ok "audit: zero direct nft writes" || no "audit nft writes" "$(cat "$NFT_WRITE_LOG")"

echo "=== S1 audit: native :55000 sshd listener (in-authority, no warn) ==="
reset_state; DETECT_PORTS=$'22\n55000'; export NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
out="$(nftban_ssh_admin_port_audit 2>&1)"
echo "$out" | grep -qi "is NOT an sshd listener" && no "native :55000 should NOT warn" "$out" || ok "audit: no mismatch when :55000 is a real listener"

echo "=== S1 audit: multi-port sshd (22 + 2222 native) ==="
reset_state; DETECT_PORTS=$'22\n2222'
out="$(nftban_ssh_admin_port_audit 2>&1)"
echo "$out" | grep -qi "is NOT an sshd listener" && no "multi-port: false warning" "$out" || ok "multi-port: no false warning"

echo "=== risk helper: declared-not-listener = at-risk; declared-listener / none = no risk ==="
reset_state; DETECT_PORTS="22"; export NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
[[ "$(_nftban_ssh_external_admin_risk_ports)" == "55000" ]] && ok "risk: declared :55000 not a listener → at-risk" || no "risk external" "$(_nftban_ssh_external_admin_risk_ports)"
reset_state; DETECT_PORTS=$'22\n55000'; export NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
[[ -z "$(_nftban_ssh_external_admin_risk_ports)" ]] && ok "risk: declared :55000 IS a listener → no risk" || no "risk native"
reset_state; DETECT_PORTS="22"
[[ -z "$(_nftban_ssh_external_admin_risk_ports)" ]] && ok "risk: nothing declared → no risk" || no "risk none"

echo "=== S2 lockout-net: external-redirect rebuild (warn + IPC whitelist) ==="
reset_state; DETECT_PORTS="22"
export SSH_CLIENT="203.0.113.7 51000 22"
export NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
out="$(nftban_ssh_pre_rebuild_lockout_guard rebuild 2>&1)"
echo "$out" | grep -q "external admin SSH port(s) (:55000) reach sshd via an EXTERNAL redirect" && ok "guard: warns on external-redirect risk port" || no "guard warn" "$out"
echo "$out" | grep -q "NOT preserve the" && ok "guard: states NAT not preserved" || no "guard nat statement" "$out"
grep -q "wl-add 203.0.113.7 --ttl 1h --reason pre-rebuild-lockout-net" "$WL_LOG" \
    && ok "guard: session-whitelists admin IP via IPC (default TTL 1h)" || no "guard wl IPC" "$(cat "$WL_LOG")"
[[ ! -s "$NFT_WRITE_LOG" ]] && ok "guard: lockout-net uses IPC only — zero direct nft writes" || no "guard nft writes" "$(cat "$NFT_WRITE_LOG")"

echo "=== S2 NARROWED: normal :22 host is a TRUE no-op (no warn, no whitelist, no nested reload) ==="
reset_state; DETECT_PORTS="22"
export SSH_CLIENT="198.51.100.9 40000 22"
out="$(nftban_ssh_pre_rebuild_lockout_guard rebuild 2>&1)"
[[ -z "$out" ]] && ok "normal :22: no output (no warning)" || no "normal :22 silent" "$out"
[[ ! -s "$WL_LOG" ]] && ok "normal :22: no session-whitelist call (so no nested reload)" || no "normal :22 wl" "$(cat "$WL_LOG")"
echo "$out" | grep -qi "external admin SSH port" && no "normal :22: must not warn external" "$out" || ok "normal :22: no external warning"

echo "=== S2 NARROWED: native :55000 listener declared is a TRUE no-op ==="
reset_state; DETECT_PORTS=$'22\n55000'
export SSH_CLIENT="203.0.113.7 51000 55000" NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
out="$(nftban_ssh_pre_rebuild_lockout_guard rebuild 2>&1)"
[[ -z "$out" ]] && ok "native :55000: no output (no warning)" || no "native :55000 silent" "$out"
[[ ! -s "$WL_LOG" ]] && ok "native :55000: no forced whitelist (in-authority listener)" || no "native :55000 wl" "$(cat "$WL_LOG")"

echo "=== S2 custom TTL (risk path) ==="
reset_state; DETECT_PORTS="22"; export SSH_CLIENT="203.0.113.7 51000 22" NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000" NFTBAN_PREREBUILD_LOCKOUT_TTL="2h"
nftban_ssh_pre_rebuild_lockout_guard takeover >/dev/null 2>&1
grep -q "wl-add 203.0.113.7 --ttl 2h --reason pre-takeover-lockout-net" "$WL_LOG" \
    && ok "guard: honors NFTBAN_PREREBUILD_LOCKOUT_TTL + per-op reason" || no "guard custom ttl/reason" "$(cat "$WL_LOG")"

echo "=== S2 dry-run (risk path): no whitelist write ==="
reset_state; DETECT_PORTS="22"; export SSH_CLIENT="203.0.113.7 51000 22" NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
out="$(nftban_ssh_pre_rebuild_lockout_guard rebuild --dry-run 2>&1)"
echo "$out" | grep -q "dry-run: would session-whitelist" && ok "dry-run: reports intent" || no "dry-run report" "$out"
[[ ! -s "$WL_LOG" ]] && ok "dry-run: no whitelist mutation" || no "dry-run no mutation" "$(cat "$WL_LOG")"

echo "=== S2 opt-out beats risk: NFTBAN_NO_PREREBUILD_LOCKOUT=1 ==="
reset_state; DETECT_PORTS="22"; export SSH_CLIENT="203.0.113.7 51000 22" NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000" NFTBAN_NO_PREREBUILD_LOCKOUT=1
out="$(nftban_ssh_pre_rebuild_lockout_guard rebuild 2>&1)"
{ [[ ! -s "$WL_LOG" ]] && [[ -z "$out" ]]; } && ok "opt-out: no whitelist, no warn (even with risk)" || no "opt-out" "$(cat "$WL_LOG") | $out"

echo "=== S2 re-entry beats risk: no recursion ==="
reset_state; DETECT_PORTS="22"; export SSH_CLIENT="203.0.113.7 51000 22" NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000" _NFTBAN_PREREBUILD_GUARD_ACTIVE=1
nftban_ssh_pre_rebuild_lockout_guard reload >/dev/null 2>&1
[[ ! -s "$WL_LOG" ]] && ok "re-entry: guard short-circuits (no recursive whitelist)" || no "re-entry" "$(cat "$WL_LOG")"

echo "=== S2 not-in-ssh beats risk: no-op ==="
reset_state; DETECT_PORTS="22"; export NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
nftban_ssh_pre_rebuild_lockout_guard rebuild >/dev/null 2>&1
[[ ! -s "$WL_LOG" ]] && ok "no ssh session: guard is a no-op (even with risk declared)" || no "no-ssh no-op" "$(cat "$WL_LOG")"

echo "=== invariant: guard NEVER imports the external port (ssh_ports unchanged) ==="
reset_state; DETECT_PORTS="22"; export SSH_CLIENT="203.0.113.7 51000 22" NFTBAN_EXTERNAL_ADMIN_SSH_PORTS="55000"
nftban_ssh_pre_rebuild_lockout_guard rebuild >/dev/null 2>&1
[[ ! -s "$NFT_WRITE_LOG" ]] && ok "REJECT-C upheld: no ssh_ports import / no nft write at all" || no "import invariant" "$(cat "$NFT_WRITE_LOG")"

echo ""
echo "================================================================"
echo "ssh_admin_port_guard: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
