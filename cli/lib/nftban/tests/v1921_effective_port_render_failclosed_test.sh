#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.192.1 - declarative service-port render FAIL-CLOSED test (inc3/inc7)
# =============================================================================
# meta:name="v1921_effective_port_render_failclosed_test"
# meta:type="test"
# meta:version="1.192.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Asserts _firewall_complete_service_ports fails closed (no skeletal fallback) and substitutes complete elements declaratively into the set blocks"
# meta:inventory.files=""
# meta:inventory.binaries="bash,perl"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v1921_effective_port_render_failclosed_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-service-port-render"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# D-V192-RESIDUAL-REBUILD-DROP inc3 (fail-closed) + inc7 (declarative):
#   A failed effective-port render must NOT produce a successful rebuild with
#   skeletal service-port sets; a successful render substitutes the COMPLETE
#   elements DECLARATIVELY inside the set blocks (no imperative flush/add).
#   Hermetic — no nft, no root, no host state.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMD_FIREWALL="$SCRIPT_DIR/../cli/cmd_firewall.sh"
[[ -f "$CMD_FIREWALL" ]] || { echo "FAIL: cmd_firewall.sh not found at $CMD_FIREWALL"; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl not available"; exit 0; }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
export NFTBAN_LIB_DIR="$SB/lib"
export NFTBAN_CONFIG_DIR="$SB/conf"
mkdir -p "$NFTBAN_LIB_DIR/bin" "$NFTBAN_LIB_DIR/lib" "$NFTBAN_CONFIG_DIR/ports.d"

# shellcheck source=/dev/null
source "$CMD_FIREWALL"
declare -f _firewall_complete_service_ports >/dev/null 2>&1 \
  || { echo "FAIL: _firewall_complete_service_ports not defined after source"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# SSH-port authority mock present by default.
nftban_detect_ssh_ports()        { printf '55000\n'; }
nftban_detect_ssh_primary_port() { printf '55000\n'; }

# Stub nftban-core: emits KEY=CSV element lines (the inc7 format).
stub_core() { # $1 exit code
  cat > "$NFTBAN_LIB_DIR/bin/nftban-core" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "ports" && "\${2:-}" == "render-effective" ]]; then
  [[ -n "\${NFTBAN_EFFECTIVE_SSH_PORTS:-}" ]] || exit 3
  printf 'NFTBAN_SVC_TCP_IN=80, 443, 993, 10051, 55000\n'
  printf 'NFTBAN_SVC_TCP_OUT=53, 80, 443, 587\n'
  printf 'NFTBAN_SVC_UDP_IN=53\n'
  printf 'NFTBAN_SVC_UDP_OUT=53, 123\n'
fi
exit ${1:-0}
STUB
  chmod +x "$NFTBAN_LIB_DIR/bin/nftban-core"
}

# A template-like conf with the 4 set blocks (ip + ip6) for substitution targets.
fresh_conf() {
  local f="$SB/conf_$RANDOM.nft"
  cat > "$f" <<'NFT'
table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 55000, 80, 443 }
	}
	set tcp_ports_out {
		type inet_service
		elements = { 53, 80, 443 }
	}
	set udp_ports_in {
		type inet_service
		comment "Allowed inbound UDP ports"
	}
	set udp_ports_out {
		type inet_service
		elements = { 53, 123 }
	}
}
NFT
  echo "$f"
}
modified() { grep -q '993' "$1"; }                 # 993 substituted into a set?
imperative() { grep -qE 'flush set|add element' "$1"; }  # must NEVER appear

echo "=== T1: nftban-core MISSING → fail-closed, conf unchanged ==="
rm -f "$NFTBAN_LIB_DIR/bin/nftban-core"
c=$(fresh_conf)
if _firewall_complete_service_ports "$c"; then bad "T1 success with binary missing"; else ok "T1 returns non-zero"; fi
modified "$c" && bad "T1 modified conf despite failure" || ok "T1 conf unchanged (no skeletal success)"

echo "=== T2: nftban-core FAILS (exit 1) → fail-closed ==="
stub_core 1; c=$(fresh_conf)
if _firewall_complete_service_ports "$c"; then bad "T2 success on render failure"; else ok "T2 returns non-zero"; fi
modified "$c" && bad "T2 modified conf despite failure" || ok "T2 conf unchanged"

echo "=== T3: nftban-core OK → success, declarative substitution ==="
stub_core 0; c=$(fresh_conf)
if _firewall_complete_service_ports "$c"; then ok "T3 returns success"; else bad "T3 non-zero on valid render"; fi
modified "$c" && ok "T3 substituted configured port 993" || bad "T3 did not substitute 993"
grep -q 'elements = { 80, 443, 993, 10051, 55000 }' "$c" && ok "T3 tcp_ports_in complete elements" || bad "T3 tcp_ports_in not complete: $(grep -m1 -A2 'set tcp_ports_in' "$c"|tr -d '\n')"
imperative "$c" && bad "T3 emitted imperative flush/add (must be declarative)" || ok "T3 declarative (no flush/add)"
grep -q 'set udp_ports_in {' "$c" && ok "T3 udp_ports_in present" || bad "T3 udp_ports_in missing"
# Empty-set insert must put `elements` on its OWN line — a merged
# `comment "..."  elements = {...}` is an nft syntax error (caught on lab4).
if grep -qE '[^[:space:]].*elements = \{' "$c"; then
  bad "T3 elements merged onto a non-blank line (nft syntax error): $(grep -nE '[^[:space:]].*elements = \{' "$c" | head -1)"
else ok "T3 every elements line stands alone (udp_ports_in insert valid)"; fi
grep -qE 'elements = \{[^}]*\b53\b' "$c" && ok "T3 udp_ports_in got 53 element" || bad "T3 udp_ports_in missing 53"

echo "=== T4: SSH authority ABSENT → fail-closed (lockout guard) ==="
stub_core 0
nftban_detect_ssh_ports()        { :; }
nftban_detect_ssh_primary_port() { :; }
rm -f "$NFTBAN_CONFIG_DIR/ports.d/00-ssh.conf"
c=$(fresh_conf)
if _firewall_complete_service_ports "$c"; then bad "T4 success without SSH authority"; else ok "T4 returns non-zero (lockout guard)"; fi
modified "$c" && bad "T4 modified conf without SSH" || ok "T4 conf unchanged"

echo ""
echo "=== v1921 declarative fail-closed: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
