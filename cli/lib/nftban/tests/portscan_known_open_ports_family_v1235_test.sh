#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - portscan classic reads the known-open ports of the IP's family
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="portscan_known_open_ports_family_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="P12-A06 / OPEN_PORTSCAN_IPV6_VERDICT_SCORED_ON_IPV4_PORTS (v1.235). _nftban_portscan_classic_known_open_ports always listed tcp_ports_in from the IPv4 table, so the Go classifier excluded the IPv4 host's open ports when scoring an IPv6 source. Both family tables carry their own tcp_ports_in (install/nftables/nftables.conf.tpl), which differ whenever ports.d differs per family. Drives the REAL function (extracted by name) against a stub nft whose two families hold DIFFERENT sets. Arms: K1 ipv4 -> the ip-table set; K2 ipv6 -> the ip6-table set (exactly; the header 'ip6' used to add a bogus port 6); K3 no argument keeps the ipv4 default; K4 the verdict builder passes the IP's family to it; K5 a wrapped multi-line elements block is read whole. Set PORTSCAN_SUBJECT_ROOT to an older tree (e.g. e79a1173): K2 and K4 must FAIL there."
# meta:inventory.files="portscan_known_open_ports_family_v1235_test.sh"
# meta:inventory.binaries="bash,awk,grep,sort,tr,mktemp"
# meta:inventory.env_vars="PORTSCAN_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="portscan_known_open_ports_family_v1235_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan-classic"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${PORTSCAN_SUBJECT_ROOT:-$REPO}"
SRC="$ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: portscan known-open ports follow the IP's family ==="
[[ -f "$SRC" ]] || { echo "  NOT_EXECUTED: $SRC missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
# Stub nft: the two families hold DIFFERENT service ports.
cat > "$W/bin/nft" <<'NFT'
#!/bin/sh
case "$*" in
    "list set ip nftban tcp_ports_in")  printf 'table ip nftban {\n\tset tcp_ports_in {\n\t\ttype inet_service\n\t\telements = { 22, 80 }\n\t}\n}\n' ;;
    "list set ip6 nftban tcp_ports_in") printf 'table ip6 nftban {\n\tset tcp_ports_in {\n\t\ttype inet_service\n\t\telements = { 22, 443, 8443 }\n\t}\n}\n' ;;
    "list set ip wrapped tcp_ports_in") printf 'table ip wrapped {\n\tset tcp_ports_in {\n\t\ttype inet_service\n\t\telements = { 21, 22, 25,\n\t\t\t     53, 110, 143 }\n\t}\n}\n' ;;
    *) exit 1 ;;
esac
NFT
chmod 0755 "$W/bin/nft"
awk '/^_nftban_portscan_classic_known_open_ports\(\) *\{/{f=1} f{print} f && /^}/{exit}' "$SRC" > "$W/fn.sh"
[[ -s "$W/fn.sh" ]] || { echo "  NOT_EXECUTED: function not found"; echo "RESULT: NOT_EXECUTED"; exit 3; }

call(){ env -i PATH="$W/bin:/usr/bin:/bin" W="$W" bash -c 'set -Eeuo pipefail; . "$W/fn.sh"; _nftban_portscan_classic_known_open_ports "$@"' _ "$@"; }

got="$(call ipv4 || true)"; [[ "$got" == "22 80 " ]] && ok "K1 ipv4 reads the ip-table set (22 80)" || no "K1 ipv4 set wrong" "got '$got'"
got="$(call ipv6 || true)"; [[ "$got" == "22 443 8443 " ]] && ok "K2 ipv6 reads the ip6-table set (22 443 8443)" || no "K2 ipv6 scored against the wrong family" "got '$got'"
got="$(call || true)";      [[ "$got" == "22 80 " ]] && ok "K3 no argument keeps the ipv4 default" || no "K3 default changed" "got '$got'"

# K5: a wrapped (multi-line) elements block, and no digits from the header.
got="$(env -i PATH="$W/bin:/usr/bin:/bin" W="$W" NFTBAN_TABLE_IPV4="ip wrapped" bash -c 'set -Eeuo pipefail; . "$W/fn.sh"; _nftban_portscan_classic_known_open_ports ipv4' || true)"
[[ "$got" == "21 22 25 53 110 143 " ]] && ok "K5 multi-line elements block read whole, header ignored" || no "K5 wrapped set misread" "got '$got'"

# K4: the verdict builder must hand the IP's family to the reader.
vb="$(awk '/^_nftban_portscan_classic_go_verdict\(\) *\{/{f=1} f{print} f && /^}/{exit}' "$SRC")"
if grep -qE 'known_open=\$\(_nftban_portscan_classic_known_open_ports "\$family"\)' <<<"$vb"; then
    ok "K4 the verdict builder passes \$family"
else
    no "K4 the verdict builder does not pass the IP family"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
