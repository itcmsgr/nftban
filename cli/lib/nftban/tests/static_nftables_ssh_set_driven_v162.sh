#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.162 PR-B: static boot-baseline SSH ct-count is set-driven (@ssh_ports)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="static_nftables_ssh_set_driven_v162"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Locks v1.162 PR-B (DELTA §3.5): the pre-rendered static fallback install/nftables/nftables.conf — the boot-baseline staged to /etc/nftban/nftables.conf, loaded at boot before the .tpl rebuild — must drive its SSH brute-force ct-count rule from @ssh_ports, not the literal 'tcp dport 22'. Migrates the static file to the set-driven form already used by nftables.conf.tpl (v1.145 PR-A). Asserts: (a) a 'set ssh_ports' block exists in BOTH 'table ip nftban' and 'table ip6 nftban'; (b) the SSH ct-count rule in each table uses 'tcp dport @ssh_ports ct count' (not literal 'tcp dport 22 ct count'); (c) no literal 'tcp dport 22 ct count' rule survives anywhere in the file; (d) define-before-use — each table's 'set ssh_ports' definition precedes its '@ssh_ports' reference (nftables requires the set to exist before use, else the boot firewall fails to load). Hermetic: reads the repo source file read-only; no nft, no host, no root."
# meta:input="None (reads repo source file read-only)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk"
# meta:inventory.files="install/nftables/nftables.conf"
# meta:inventory.binaries="bash,grep,awk"
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
CONF="$REPO_ROOT/install/nftables/nftables.conf"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$CONF" ]] || { echo "static config not found: $CONF"; exit 1; }

echo "=== (a) 'set ssh_ports' declared in BOTH ip and ip6 tables ==="
# Count one declaration per table; expect exactly 2 across the file.
defs=$(grep -cE '^[[:space:]]*set ssh_ports \{' "$CONF" || true)
if [[ "$defs" -eq 2 ]]; then
  ok "set ssh_ports declared twice (ip + ip6), found $defs"
else
  no "expected 2 'set ssh_ports' blocks (ip+ip6), found $defs"
fi

echo "=== (b) SSH ct-count rule is set-driven (@ssh_ports) in both tables ==="
uses=$(grep -cE 'ct state new tcp dport @ssh_ports ct count' "$CONF" || true)
if [[ "$uses" -eq 2 ]]; then
  ok "SSH ct-count uses @ssh_ports in both tables, found $uses"
else
  no "expected 2 set-driven SSH ct-count rules, found $uses"
fi

echo "=== (c) no literal 'tcp dport 22 ct count' rule survives ==="
if grep -qE 'tcp dport 22 ct count' "$CONF"; then
  no "literal 'tcp dport 22 ct count' still present (boot-baseline not migrated)"
else
  ok "no literal 'tcp dport 22 ct count' rule remains"
fi

echo "=== (d) define-before-use: 'set ssh_ports' precedes '@ssh_ports' in each table ==="
# Per-table check: within each 'table ip[6]? nftban' block the set definition
# line number must be strictly less than the @ssh_ports reference line number.
# nftables loads the file top-to-bottom; a forward reference fails at boot.
report=$(awk '
  /^table ip nftban/   { tbl="ip";  defline=0; useline=0 }
  /^table ip6 nftban/  { tbl="ip6"; defline=0; useline=0 }
  /^[[:space:]]*set ssh_ports \{/ { if (tbl!="" && defline==0) defline=NR }
  /ct state new tcp dport @ssh_ports ct count/ { if (tbl!="" && useline==0) { useline=NR; printf "%s %d %d\n", tbl, defline, useline } }
' "$CONF")
[[ -n "$report" ]] || { no "could not locate set/use pairs per table"; }
# Split each "tbl def use" record on whitespace (the script-wide IFS excludes
# spaces, so set a local space-aware IFS just for this read loop).
while IFS=' ' read -r tbl defline useline; do
  [[ -z "$tbl" ]] && continue
  if [[ "$defline" -gt 0 && "$useline" -gt 0 && "$defline" -lt "$useline" ]]; then
    ok "table $tbl: ssh_ports defined @line $defline before use @line $useline"
  else
    no "table $tbl: define-before-use violated (def=$defline use=$useline)"
  fi
done <<< "$report"

echo "================================================================"
echo "static_nftables_ssh_set_driven_v162: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
