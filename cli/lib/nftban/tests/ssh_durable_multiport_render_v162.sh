#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.162: SSH durable multi-port render + reboot-sim regression (shell)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ssh_durable_multiport_render_v162"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Locks v1.162 DELTA §3.1 on the SHELL durable-render path (cmd_firewall.sh _firewall_substitute_placeholders). __SSH_PORT__ appears ONLY inside `set ssh_ports { elements = { … } }` and tcp_ports_in, so the function substitutes the FULL detected SSH-port union (comma-separated), never primary-only. The test mocks nftban_detect_ssh_ports to return a multi-port union (22, 2222, 55000), renders the real install/nftables/nftables.conf.tpl into a TMPDIR output, and asserts: (a) every union port (22 AND 2222 AND 55000) is present in the rendered ssh_ports elements; (b) the SSH ct-count rule renders set-driven `tcp dport @ssh_ports`; (c) no __SSH_PORT__ placeholder remains; (d) NEGATIVE — when multiple ports are detected the ssh_ports render is NOT primary-only (carries the additional ports too). Reboot-sim: the written output is the durable file; it is re-read fresh and the union ports must all still be present (the durable file alone carries them, no kernel reconcile). Hermetic: TMPDIR sandbox, mocked detection, no host/systemd/sshd."
# meta:input="None (self-contained; sources cmd_firewall.sh with a mocked detector)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,install/nftables/nftables.conf.tpl"
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
CMD_FIREWALL="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
TEMPLATE="$REPO_ROOT/install/nftables/nftables.conf.tpl"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$CMD_FIREWALL" ]] || { echo "cmd_firewall.sh not found: $CMD_FIREWALL"; exit 1; }
[[ -f "$TEMPLATE" ]]     || { echo "template not found: $TEMPLATE"; exit 1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# -----------------------------------------------------------------------------
# Isolate _firewall_substitute_placeholders from its host environment.
#
# cmd_firewall.sh runs `set -Eeuo pipefail` and sources several /usr/lib/nftban
# libs at top level, but every source is guarded (`|| true` / conditional on a
# present file), so on a host without /usr/lib/nftban they are harmless no-ops.
# Point NFTBAN_LIB_DIR at an empty sandbox so the real ssh_port_detect.sh is NOT
# sourced, then define a MOCK nftban_detect_ssh_ports returning a multi-port
# union AFTER sourcing. The function re-sources ssh_port_detect.sh from
# NFTBAN_LIB_DIR (a no-op here, guarded by `|| true`), so our mock survives and
# is the function actually called when computing the union CSV.
# -----------------------------------------------------------------------------
export NFTBAN_LIB_DIR="$SB/empty-lib"
export NFTBAN_CONFIG_DIR="$SB/empty-conf"   # no ports.d fallback file -> live mock wins
mkdir -p "$NFTBAN_LIB_DIR" "$NFTBAN_CONFIG_DIR"

# Source the command file (only the function definitions are needed; no
# subcommand is dispatched). Guarded sources resolve to no-ops in the sandbox.
# shellcheck source=/dev/null
source "$CMD_FIREWALL"

declare -f _firewall_substitute_placeholders >/dev/null 2>&1 \
  || { echo "_firewall_substitute_placeholders not defined after source"; exit 1; }

# Mock the live detector with a multi-port union (primary-first). Defined AFTER
# the source so it shadows any real definition; the function re-sources
# ssh_port_detect.sh from the empty sandbox (no-op) before calling this.
SSH_UNION_PORTS=(22 2222 55000)
nftban_detect_ssh_ports() { printf '22\n2222\n55000\n'; }
nftban_detect_ssh_primary_port() { printf '22\n'; }
export -f nftban_detect_ssh_ports nftban_detect_ssh_primary_port 2>/dev/null || true

OUT="$SB/nftables.conf.rendered"

echo "=== render real template with mocked multi-port union (22, 2222, 55000) ==="
_firewall_substitute_placeholders "$TEMPLATE" "$OUT" \
  || { echo "render returned non-zero"; exit 1; }
[[ -s "$OUT" ]] || { echo "rendered output is empty: $OUT"; exit 1; }
ok "rendered $TEMPLATE -> $OUT"

# Helper: extract the inner `elements = { … }` of every `set ssh_ports` block.
# The template has one per family (ip + ip6). awk keeps it dependency-light.
ssh_ports_elements() {
  awk '
    /set ssh_ports[[:space:]]*\{/ { inblk=1 }
    inblk && /elements[[:space:]]*=[[:space:]]*\{/ {
      line=$0
      sub(/.*elements[[:space:]]*=[[:space:]]*\{/, "", line)
      sub(/\}.*/, "", line)
      print line
      inblk=0
    }
  ' "$1"
}

# -----------------------------------------------------------------------------
# (a) every union port present in the rendered ssh_ports elements
# -----------------------------------------------------------------------------
echo "=== (a) every union port lands in ssh_ports elements (both families) ==="
SSH_ELEMS="$(ssh_ports_elements "$OUT")"
[[ -n "$SSH_ELEMS" ]] || { echo "no ssh_ports elements extracted"; exit 1; }
# Expect two ssh_ports blocks (ip + ip6).
nblk="$(printf '%s\n' "$SSH_ELEMS" | grep -c .)"
if [[ "$nblk" -eq 2 ]]; then ok "two ssh_ports blocks rendered (ip + ip6)"
else no "expected 2 ssh_ports blocks, got $nblk"; fi

union_in_every_block() {
  # $1 = port. Assert it appears as a whole token in EVERY ssh_ports block.
  local port="$1" miss=0
  while IFS= read -r blk; do
    [[ -z "$blk" ]] && continue
    if ! printf '%s' "$blk" | grep -Eq "(^|[^0-9])${port}([^0-9]|$)"; then
      miss=1
    fi
  done < <(printf '%s\n' "$SSH_ELEMS")
  return $miss
}

for p in "${SSH_UNION_PORTS[@]}"; do
  if union_in_every_block "$p"; then
    ok "union port $p present in every ssh_ports block"
  else
    no "union port $p MISSING from an ssh_ports block (primary-only regression?)" "elements: $SSH_ELEMS"
  fi
done

# -----------------------------------------------------------------------------
# (b) SSH ct-count rule renders set-driven @ssh_ports (not a literal port)
# -----------------------------------------------------------------------------
echo "=== (b) SSH ct-count rule is set-driven (tcp dport @ssh_ports) ==="
if grep -Eq 'tcp dport @ssh_ports ct count' "$OUT"; then
  ok "ct-count rule reads @ssh_ports"
else
  no 'set-driven tcp dport @ssh_ports ct count rule not found'
fi
for p in "${SSH_UNION_PORTS[@]}"; do
  if grep -Eq "tcp dport ${p} ct count" "$OUT"; then
    no "found literal tcp dport ${p} ct count — SSH rule must use @ssh_ports"
  fi
done
ok "no literal per-port SSH ct-count rule"

# -----------------------------------------------------------------------------
# (c) no __SSH_PORT__ placeholder remains
# -----------------------------------------------------------------------------
echo "=== (c) no unrendered __SSH_PORT__ placeholder remains ==="
if grep -q '__SSH_PORT__' "$OUT"; then
  no "unrendered __SSH_PORT__ placeholder present in durable output"
else
  ok "no __SSH_PORT__ placeholder remains"
fi

# -----------------------------------------------------------------------------
# (d) NEGATIVE — multi-port render is NOT primary-only
# -----------------------------------------------------------------------------
echo "=== (d) NEGATIVE: ssh_ports is NOT primary-only when multiple ports detected ==="
# If render had collapsed to primary-only, the additional ports (2222, 55000)
# would be absent. Assert at least one additional port IS present somewhere.
if printf '%s' "$SSH_ELEMS" | grep -Eq '(^|[^0-9])2222([^0-9]|$)' \
   && printf '%s' "$SSH_ELEMS" | grep -Eq '(^|[^0-9])55000([^0-9]|$)'; then
  ok "additional ports 2222 + 55000 present (not primary-only)"
else
  no "ssh_ports collapsed to primary-only — additional ports missing" "elements: $SSH_ELEMS"
fi

# -----------------------------------------------------------------------------
# Reboot-sim: the written output IS the durable file. Re-read it fresh (no
# kernel reconcile) and assert every union port still present.
# -----------------------------------------------------------------------------
echo "=== reboot-sim: re-read durable file fresh; union must survive ==="
DURABLE="$SB/durable-after-reboot.conf"
cp "$OUT" "$DURABLE"   # the file that survives a reboot
SSH_ELEMS="$(ssh_ports_elements "$DURABLE")"   # re-parse fresh from disk
reboot_ok=1
for p in "${SSH_UNION_PORTS[@]}"; do
  union_in_every_block "$p" || reboot_ok=0
done
if [[ "$reboot_ok" -eq 1 ]]; then
  ok "all union ports survive in the durable file alone (no reconcile needed)"
else
  no "a union port did NOT survive in the durable file" "elements: $SSH_ELEMS"
fi

echo "================================================================"
echo "ssh_durable_multiport_render_v162: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
