#!/usr/bin/env bash
# =============================================================================
# NFTBan - nftban search: "Found in nftables sets" names the set (v1.236)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="search_found_sets_display_v1236_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-03"
# meta:description="Hermetic test for cmd_search.sh _display_results: an address found in blacklist_manual (location nftban:blacklist:manual) is listed under Found in nftables sets with its ban type (v1.234.0 printed an empty list), and the set is read from the family of the address (ip6 for IPv6). nft is a stub function."
#
# meta:inventory.files="search_found_sets_display_v1236_test.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="search_found_sets_display_v1236_test"
# meta:ta.owner="cli"
# meta:ta.module="search"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
NFTBAN_CONFIG_DIR="$tmp/etc"; export NFTBAN_CONFIG_DIR; mkdir -p "$NFTBAN_CONFIG_DIR"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/cli/cmd_search.sh"
set +e +u; trap - ERR

# nft stub on PATH (the code runs it through `timeout`, which executes a binary): records the
# arguments; a timed element only in the ip6 manual set.
NFT_ARGS="$tmp/nft_args"; : > "$NFT_ARGS"; export NFT_ARGS
mkdir -p "$tmp/bin"
cat > "$tmp/bin/nft" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$NFT_ARGS"
case "$*" in
    "list set ip6 nftban blacklist_manual_ipv6") echo "elements = { 2001:db8::5 timeout 1h expires 59m2s }" ;;
    "list set ip nftban blacklist_manual_ipv4")  echo "elements = { 185.42.211.245 }" ;;
esac
exit 0
STUB
chmod 755 "$tmp/bin/nft"; PATH="$tmp/bin:$PATH"; export PATH

out=$(_display_results "185.42.211.245" $'FOUND\nnftban:blacklist:manual' "" 2>&1)
grep -q "STATUS: BANNED" <<< "$out" || fail "v4: status line missing"
grep -q "BLACKLISTED in nftban (hash set" <<< "$out" || fail "v4: set not listed under Found in nftables sets: $out"
grep -q "Type: Permanent ban" <<< "$out" || fail "v4: permanent type not shown"
grep -q "^list set ip nftban blacklist_manual_ipv4$" "$NFT_ARGS" || fail "v4: set not read from family ip: $(cat "$NFT_ARGS")"
pass "IPv4 manual ban is listed with its type"

: > "$NFT_ARGS"
out=$(_display_results "2001:db8::5" $'FOUND\nnftban:blacklist:manual' "" 2>&1)
grep -q "BLACKLISTED in nftban (hash set" <<< "$out" || fail "v6: set not listed"
grep -q "Type: Temporary ban (timeout 1h)" <<< "$out" || fail "v6: timed ban not read from ip6: $out"
grep -q "^list set ip6 nftban blacklist_manual_ipv6$" "$NFT_ARGS" || fail "v6: set not read from family ip6"
pass "IPv6 manual ban is read from ip6 and shows its timeout"

out=$(_display_results "198.51.100.7" $'FOUND\nnftban:whitelist' "" 2>&1)
grep -q "STATUS: WHITELISTED" <<< "$out" && grep -q "WHITELISTED in nftban" <<< "$out" || fail "whitelist display changed: $out"
pass "whitelist display unchanged"
echo "ALL PASS"
