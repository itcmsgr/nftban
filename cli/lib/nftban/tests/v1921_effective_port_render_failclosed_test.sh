#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.192.1 - effective service-port render FAIL-CLOSED test (Increment 3)
# =============================================================================
# meta:name="v1921_effective_port_render_failclosed_test"
# meta:type="test"
# meta:version="1.192.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Asserts _firewall_append_effective_ports fails closed (no silent skeletal fallback) so a failed effective-port render cannot produce a successful rebuild with skeletal service-port sets"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# D-V192-RESIDUAL-REBUILD-DROP Increment 3 acceptance:
#   A failed effective-port render must NOT result in a successful rebuild with
#   skeletal service-port sets. The completion step fails closed; the rebuild
#   caller aborts before `nft -f`. Hermetic — no nft, no root, no host state.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMD_FIREWALL="$SCRIPT_DIR/../cli/cmd_firewall.sh"
[[ -f "$CMD_FIREWALL" ]] || { echo "FAIL: cmd_firewall.sh not found at $CMD_FIREWALL"; exit 1; }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
export NFTBAN_LIB_DIR="$SB/lib"
export NFTBAN_CONFIG_DIR="$SB/conf"
mkdir -p "$NFTBAN_LIB_DIR/bin" "$NFTBAN_LIB_DIR/lib" "$NFTBAN_CONFIG_DIR/ports.d"

# shellcheck source=/dev/null
source "$CMD_FIREWALL"
declare -f _firewall_append_effective_ports >/dev/null 2>&1 \
  || { echo "FAIL: _firewall_append_effective_ports not defined after source"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# SSH-port authority mock present by default (so non-SSH tests isolate the binary).
nftban_detect_ssh_ports()        { printf '55000\n'; }
nftban_detect_ssh_primary_port() { printf '55000\n'; }

stub_core() { # $1 = exit code, $2 = stdout
  cat > "$NFTBAN_LIB_DIR/bin/nftban-core" <<STUB
#!/usr/bin/env bash
printf '%s' "${2:-}"
exit ${1:-0}
STUB
  chmod +x "$NFTBAN_LIB_DIR/bin/nftban-core"
}
fresh_conf() { local f="$SB/conf_$RANDOM.nft"; printf 'table ip nftban { }\n' > "$f"; echo "$f"; }
has_frag() { grep -q 'effective service-port sets' "$1"; }

echo "=== T1: nftban-core MISSING → fail-closed, no skeletal append ==="
rm -f "$NFTBAN_LIB_DIR/bin/nftban-core"
c=$(fresh_conf)
if _firewall_append_effective_ports "$c"; then bad "T1 returned success with binary missing"; else ok "T1 returns non-zero (binary missing)"; fi
has_frag "$c" && bad "T1 appended a fragment despite failure" || ok "T1 conf NOT modified (no skeletal success)"

echo "=== T2: nftban-core FAILS (exit 1) → fail-closed ==="
stub_core 1 ""
c=$(fresh_conf)
if _firewall_append_effective_ports "$c"; then bad "T2 returned success on render failure"; else ok "T2 returns non-zero (render exit 1)"; fi
has_frag "$c" && bad "T2 appended despite failure" || ok "T2 conf NOT modified"

echo "=== T3: nftban-core OK → success, fragment appended ==="
stub_core 0 $'flush set ip nftban tcp_ports_in\nadd element ip nftban tcp_ports_in { 80, 443, 993, 10051, 55000 }\n'
c=$(fresh_conf)
if _firewall_append_effective_ports "$c"; then ok "T3 returns success"; else bad "T3 returned non-zero on valid render"; fi
has_frag "$c" && ok "T3 fragment appended" || bad "T3 fragment missing"
grep -q '993' "$c" && grep -q '10051' "$c" && ok "T3 configured ports present (993,10051)" || bad "T3 configured ports missing"

echo "=== T4: SSH authority ABSENT → fail-closed (lockout guard) ==="
stub_core 0 $'flush set ip nftban tcp_ports_in\n'
nftban_detect_ssh_ports()        { :; }   # no SSH detected
nftban_detect_ssh_primary_port() { :; }
rm -f "$NFTBAN_CONFIG_DIR/ports.d/00-ssh.conf"
c=$(fresh_conf)
if _firewall_append_effective_ports "$c"; then bad "T4 returned success without SSH authority"; else ok "T4 returns non-zero (no SSH → lockout guard)"; fi
has_frag "$c" && bad "T4 appended without SSH" || ok "T4 conf NOT modified"

echo ""
echo "=== v1921 fail-closed: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
