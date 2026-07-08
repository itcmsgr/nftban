#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.218.10 blacklist flush/count manual-set truth hotfix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="blacklist_flush_manual_truth_v218_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-08"
# meta:description="Verifies the v1.218.10 fix where `nftban blacklist flush` and `nftban flush all` omitted the manual blacklist sets (blacklist_manual_ipv4/ipv6) where botscan/admin/portscan/login/ddos-escalated bans live — so an emergency flush left hundreds of bans active while wiping feed protection. Asserts: bare blacklist flush (scope all) targets all 4 blacklist sets; scope feeds targets only interval sets; scope manual targets only manual sets; invalid scope errors; flush all now includes the manual sets; whitelist is never in the blacklist-flush set list; the prompt shows the feed+GeoBan / manual+botscan breakdown and the persistent-blacklist.d + whitelist-preserved warnings. No new nft sets are created; existing sets only."
# meta:input="None (self-contained; extracts + stubs the flush functions)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_flush.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
SRC="$REPO_ROOT/cli/lib/nftban/cli/cmd_flush.sh"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
CALLS="$SANDBOX/calls"

PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ printf '%s' "$1" | grep -Fq -- "$2"; }

# Extract the two contiguous function blocks under test.
{
  awk '/^# Count kernel elements in one set/{c=1} /^# Flush whitelist sets/{c=0} c{print}' "$SRC"
  awk '/^_flush_all\(\)/{c=1} c{print} /^}$/{if(c)exit}' "$SRC"
} > "$SANDBOX/funcs.sh"

# Harness: stubs (defined before the extracted funcs are sourced).
run() {  # run <flush_fn-with-args...>; echoes stdout; records flushed sets in $CALLS
  : > "$CALLS"
  bash -c '
    set +e
    NFTBAN_TABLE_IPV4="ip nftban"; NFTBAN_TABLE_IPV6="ip6 nftban"
    CALLS="'"$CALLS"'"
    nft(){ echo "set x { type ipv4_addr; elements = { 1.2.3.4, 5.6.7.8 } }"; }
    timeout(){ shift; "$@"; }
    _flush_check_daemon(){ return 0; }
    _flush_set_via_ipc(){ echo "$2" >> "$CALLS"; return 0; }
    _restore_system_whitelist(){ :; }
    _nftban_flush_help(){ :; }
    source "'"$SANDBOX"'/funcs.sh"
    "$@"
  ' _ "$@"
}

echo "=== v1.218.10 blacklist flush/count manual-set truth ==="

# T1 — bare scope=all flushes ALL FOUR blacklist sets
rc=0; out=$(run _flush_blacklist true false all) || rc=$?
for s in blacklist_ipv4 blacklist_ipv6 blacklist_manual_ipv4 blacklist_manual_ipv6; do
  grep -qx "$s" "$CALLS" && ok "all: flushed $s" || no "all: did NOT flush $s"
done
grep -qx whitelist_ipv4 "$CALLS" && no "all: WHITELIST flushed (must not)" || ok "all: whitelist NOT flushed"

# T2 — scope=feeds flushes only interval sets
run _flush_blacklist true false feeds >/dev/null
grep -qx blacklist_ipv4 "$CALLS" && grep -qx blacklist_ipv6 "$CALLS" && ok "feeds: flushed interval sets" || no "feeds: interval sets"
grep -qx blacklist_manual_ipv4 "$CALLS" && no "feeds: manual flushed (must not)" || ok "feeds: manual NOT flushed"

# T3 — scope=manual flushes only manual sets
run _flush_blacklist true false manual >/dev/null
grep -qx blacklist_manual_ipv4 "$CALLS" && grep -qx blacklist_manual_ipv6 "$CALLS" && ok "manual: flushed manual sets" || no "manual: manual sets"
grep -qx blacklist_ipv4 "$CALLS" && no "manual: feed flushed (must not)" || ok "manual: feed NOT flushed"

# T4 — invalid scope errors (rc 2), flushes nothing
rc=0; out=$(run _flush_blacklist true false bogus) || rc=$?
[[ "$rc" == 2 ]] && ok "invalid scope -> rc2" || no "invalid scope rc ($rc)"
[[ ! -s "$CALLS" ]] && ok "invalid scope flushed nothing" || no "invalid scope flushed sets"

# T5 — flush all now includes the manual sets
run _flush_all true false >/dev/null
grep -qx blacklist_manual_ipv4 "$CALLS" && grep -qx blacklist_manual_ipv6 "$CALLS" && ok "flush all: includes manual sets" || no "flush all: manual sets MISSING"
grep -qx blacklist_ipv4 "$CALLS" && ok "flush all: still flushes feed sets" || no "flush all: feed sets"

# T6 — dry-run shows the authority breakdown + warnings, lists all 4 sets
out=$(run _flush_blacklist false true all)
has "$out" "Feed + GeoBan"      && ok "prompt: feed+GeoBan label"      || no "prompt: feed+GeoBan label"
has "$out" "Manual + BotScan"   && ok "prompt: manual+botscan label"  || no "prompt: manual+botscan label"
has "$out" "blacklist.d"        && ok "prompt: persistent blacklist.d warning" || no "prompt: persistent warning"
has "$out" "PRESERVED"          && ok "prompt: whitelist preserved note" || no "prompt: whitelist preserved"
has "$out" "blacklist_manual_ipv4" && ok "dry-run: lists manual set" || no "dry-run: manual set"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
