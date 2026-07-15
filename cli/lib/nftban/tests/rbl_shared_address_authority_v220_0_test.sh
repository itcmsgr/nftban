#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.220.0 PR-B: shared host-address inventory authority + RBL migration
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_shared_address_authority_v220_0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-10"
# meta:description="Locks the v1.220.0 PR-B contract: core/nftban_hostaddr.sh is the single classified host-address inventory authority (DISCOVER ONCE / CLASSIFY ONCE / PROJECT PER CONSUMER). Uses a stubbed `ip` to drive a fixed interface set and asserts: full IPv4/IPv6 preserved (no first-colon 2a01 truncation, no ip:tag), scope classification (public/private/ula/cgnat/link-local/loopback/multicast/doc), RBL projection excludes non-public + tentative/deprecated/temporary + down-interface + dedups, status==rbl projection, whitelist projection parity vs legacy get_interface_ips, IPv6-safe critical-IP parsing (legacy v4 + new pipe), false-clean fix (degraded never renders/persists as clean; inventory-failure => not clean; rc contract 0/1/2), and the anti-duplication source guards. Shell-only; RBL stays observe-only; daemon byte-identical."
# meta:input="Stubbed `ip` fixtures + repo source files"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sort"
# meta:inventory.files="cli/lib/nftban/core/nftban_hostaddr.sh,cli/lib/nftban/core/nftban_rbl.sh,cli/lib/nftban/cli/cmd_rbl.sh,cli/lib/nftban/core/nftban_system_ip.sh"
# meta:inventory.binaries="bash,awk,grep,sort"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

# Coding-standard header requires this line; the harness itself runs lenient (set +eE
# below) so failing assertions accumulate instead of aborting.
set -Eeuo pipefail
set +eE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Resolve lib root for BOTH the repo tree (cli/lib/nftban/tests) and an installed FHS
# tree (/usr/lib/nftban/tests): tests/ and core/ are always siblings.
if [[ -f "$SCRIPT_DIR/../core/nftban_hostaddr.sh" ]]; then
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)/cli/lib/nftban"
fi
export NFTBAN_LIB_DIR
HOSTADDR="$NFTBAN_LIB_DIR/core/nftban_hostaddr.sh"
RBL_CORE="$NFTBAN_LIB_DIR/core/nftban_rbl.sh"
CMD_RBL="$NFTBAN_LIB_DIR/cli/cmd_rbl.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ [[ "$1" == *"$2"* ]]; }
# line-exact membership (an address is a whole line, not a substring — '::1' must
# not match inside '2a01:…::1').
hasline(){ printf '%s\n' "$1" | grep -qxF "$2"; }

# ---------------------------------------------------------------------------
# Stubbed `ip`: a fixed interface set exercising every classification branch.
#   eth0 (up):  public v4, private v4, CGNAT v4, public v6 x2, ULA v6, link-local
#               v6, temporary v6, tentative v6
#   eth1 (up):  duplicate of the public v4 (dedup test)
#   down0 (DOWN): a public v4 on a down interface (must be excluded from RBL)
#   lo (up):    loopback v4/v6
# ---------------------------------------------------------------------------
ip() {
  local joined="$*"
  if [[ "$joined" == *"link show up"* ]]; then
    cat <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
4: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
EOF
    return 0
  fi
  if [[ "$joined" == *"-o addr show"* || "$joined" == "-o addr show" ]]; then
    cat <<'EOF'
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
1: lo    inet6 ::1/128 scope host \       valid_lft forever preferred_lft forever
2: eth0    inet 192.0.2.67/24 brd 192.0.2.67 scope global eth0\       valid_lft forever preferred_lft forever
2: eth0    inet 10.0.0.5/24 scope global eth0\       valid_lft forever preferred_lft forever
2: eth0    inet 100.64.0.9/10 scope global eth0\       valid_lft forever preferred_lft forever
2: eth0    inet6 2001:db8:c014:5ee1::1/64 scope global \       valid_lft forever preferred_lft forever
2: eth0    inet6 2001:db8:c014:5ee1::2/64 scope global \       valid_lft forever preferred_lft forever
2: eth0    inet6 fd12::9/64 scope global \       valid_lft forever preferred_lft forever
2: eth0    inet6 fe80::1/64 scope link \       valid_lft forever preferred_lft forever
2: eth0    inet6 2001:db8:c014:5ee1::dead/64 scope global temporary dynamic \       valid_lft 600sec preferred_lft 600sec
2: eth0    inet6 2001:db8:c014:5ee1::beef/64 scope global tentative \       valid_lft forever preferred_lft forever
4: eth1    inet 192.0.2.67/24 scope global eth1\       valid_lft forever preferred_lft forever
3: down0    inet 8.8.4.4/24 scope global down0\       valid_lft forever preferred_lft forever
EOF
    return 0
  fi
  return 0
}
export -f ip

# shellcheck source=/dev/null
source "$HOSTADDR"
set +eE   # the lib enables set -e when sourced; keep the harness lenient

echo "=== v1.220.0 shared host-address inventory authority ==="

RBL="$(nftban_hostaddr_project_rbl)"
WL="$(nftban_hostaddr_project_whitelist)"
STATUS="$(nftban_hostaddr_project_status)"

# T1 public IPv4 selected
hasline "$RBL" "192.0.2.67" && ok "T1 public IPv4 in RBL projection" || no "T1 public IPv4 missing"

# T2 full compressed IPv6 preserved intact (no 2a01 truncation)
hasline "$RBL" "2001:db8:c014:5ee1::1" && ok "T2 full IPv6 preserved (::1)" || no "T2 IPv6 ::1 truncated/missing"
{ ! hasline "$RBL" "2a01"; } && ok "T2b no '2a01' truncation" || no "T2b IPv6 truncated to 2a01"

# T3 multiple distinct IPv6 preserved
hasline "$RBL" "2001:db8:c014:5ee1::2" && ok "T3 second distinct IPv6 preserved" || no "T3 second IPv6 missing"

# T4 private IPv4 excluded from RBL, retained by whitelist
{ ! hasline "$RBL" "10.0.0.5"; } && hasline "$WL" "10.0.0.5" && ok "T4 private v4: RBL-excluded, whitelist-kept" || no "T4 private v4 policy wrong"

# T5 ULA excluded from RBL, retained by whitelist
{ ! hasline "$RBL" "fd12::9"; } && hasline "$WL" "fd12::9" && ok "T5 ULA: RBL-excluded, whitelist-kept" || no "T5 ULA policy wrong"

# T6 CGNAT excluded from RBL
{ ! hasline "$RBL" "100.64.0.9"; } && ok "T6 CGNAT excluded from RBL" || no "T6 CGNAT leaked into RBL"

# T7 loopback + link-local excluded from RBL
{ ! hasline "$RBL" "127.0.0.1" && ! hasline "$RBL" "::1" && ! hasline "$RBL" "fe80::1"; } && ok "T7 loopback+link-local excluded from RBL" || no "T7 loopback/link-local leaked"

# T8 tentative / temporary / down-interface excluded from RBL
{ ! hasline "$RBL" "2001:db8:c014:5ee1::beef" && ! hasline "$RBL" "2001:db8:c014:5ee1::dead" && ! hasline "$RBL" "8.8.4.4"; } && ok "T8 tentative/temporary/down-iface excluded" || no "T8 excluded-state leaked into RBL"

# T9 duplicate address (eth0+eth1) -> single RBL entry
[[ "$(printf '%s\n' "$RBL" | grep -c '^46\.225\.150\.67$')" == "1" ]] && ok "T9 duplicate address deduped to one" || no "T9 duplicate not deduped"

# T10 no ip:tag / colon-tag serialization in any projection line
{ ! has "$RBL" ":ipv4" && ! has "$RBL" ":ipv6"; } && ok "T10 no :ipv4/:ipv6 tag encoding" || no "T10 colon-tag encoding present"

# T11/T12 status projection == RBL projection (same full-address input)
[[ "$STATUS" == "$RBL" ]] && ok "T11/T12 status projection == RBL scheduled input" || no "T11/T12 status != RBL projection"

# T16 whitelist projection parity vs legacy get_interface_ips
LEGACY="$(ip -o addr show 2>/dev/null | awk '/inet/ {gsub(/\/.*/, "", $4); print $4}' | grep -v '^127\.' | grep -v '^::1$' | sort -u)"
[[ "$WL" == "$LEGACY" ]] && ok "T16 whitelist projection == legacy get_interface_ips (parity)" || { no "T16 whitelist parity broken"; diff <(echo "$LEGACY") <(echo "$WL") | head; }

# scope classification spot-checks
_scope_ok=1
for pair in "192.0.2.67=public" "2001:db8::1=public" "10.0.0.5=private" "100.64.0.9=cgnat" \
            "fd12::9=ula" "fcab::1=ula" "fe80::1=link-local" "169.254.1.1=link-local" \
            "::1=loopback" "127.0.0.1=loopback" "ff02::1=multicast" "224.0.0.1=multicast" \
            "192.0.2.9=documentation" "2001:db8::5=documentation"; do
  a="${pair%=*}"; want="${pair#*=}"; got="$(nftban_hostaddr_scope "$a")"
  [[ "$got" == "$want" ]] || { _scope_ok=0; echo "        scope($a)=$got want=$want"; }
done
[[ $_scope_ok -eq 1 ]] && ok "scope classification correct (incl ULA fc00::/7, CGNAT, doc)" || no "scope classification wrong"

# inventory has no side effects (read-only): run twice, identical, no files written
snap_before="$(ls -la /tmp 2>/dev/null | wc -l)"
_a="$(nftban_hostaddr_inventory)"; _b="$(nftban_hostaddr_inventory)"
snap_after="$(ls -la /tmp 2>/dev/null | wc -l)"
[[ "$_a" == "$_b" && "$snap_before" == "$snap_after" ]] && ok "inventory deterministic + side-effect-free" || no "inventory non-deterministic or wrote files"

# JSON projection carries same addresses
J="$(nftban_hostaddr_inventory --json)"
has "$J" '"address":"2001:db8:c014:5ee1::1"' && has "$J" '"scope":"public"' && ok "JSON inventory carries full fields" || no "JSON inventory malformed"

# ---------------------------------------------------------------------------
# Critical-IP IPv6-safe parsing (source RBL core; keep the stubbed ip)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$RBL_CORE" 2>/dev/null || true
set +eE   # the strict-mode lib flips set -e on when sourced; keep the harness lenient

# T18 legacy IPv4 ip:tag still readable
out="$(NFTBAN_RBL_CRITICAL_IPS='1.2.3.4:mail,5.6.7.8:web' nftban_rbl_get_critical_ips)"
has "$out" $'1.2.3.4\tmail' && has "$out" $'5.6.7.8\tweb' && ok "T18 legacy IPv4 ip:tag critical config still read" || no "T18 legacy critical parse broke ($out)"

# T19 IPv6-safe new format round-trip (never split IPv6 at colon)
out="$(NFTBAN_RBL_CRITICAL_IPS='2001:db8:c014:5ee1::1|mail,203.0.113.5|web' nftban_rbl_get_critical_ips)"
has "$out" $'2001:db8:c014:5ee1::1\tmail' && ok "T19 new ip|tag preserves full IPv6" || no "T19 new IPv6 critical parse wrong ($out)"
out="$(NFTBAN_RBL_CRITICAL_IPS='2001:db8:c014:5ee1::1' nftban_rbl_get_critical_ips)"
has "$out" $'2001:db8:c014:5ee1::1\t' && ! has "$out" $'2a01\t' && ok "T19b bare IPv6 critical not split at colon" || no "T19b bare IPv6 split ($out)"

# is_public delegates to authority (classify once)
nftban_rbl_is_public_ip 192.0.2.67 && ! nftban_rbl_is_public_ip fd12::9 && ok "is_public delegates to authority" || no "is_public delegation wrong"

# get_public_ips (RBL projection) honors IPv6 gate
g6="$(NFTBAN_RBL_CHECK_IPV6=YES nftban_rbl_get_public_ips)"
g4="$(NFTBAN_RBL_CHECK_IPV6=NO  nftban_rbl_get_public_ips)"
has "$g6" "2001:db8:c014:5ee1::1" && ! has "$g4" ":" && has "$g4" "192.0.2.67" && ok "get_public_ips honors IPv6 gate" || no "get_public_ips IPv6 gate wrong"

# ---------------------------------------------------------------------------
# T13/T14/T15 false-clean fix — drive nftban_cmd_rbl_server with stubbed checker
# ---------------------------------------------------------------------------
run_server() { # $1 = results string the checker returns ; prints verdict output + RC
  local RESULTS="$1"
  (
    # shellcheck source=/dev/null
    source "$RBL_CORE" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$CMD_RBL" 2>/dev/null || true
    set +eE   # sourced strict-mode libs flip set -e; a nonzero rc must not abort us
    export NFTBAN_RBL_CACHE_DIR; NFTBAN_RBL_CACHE_DIR="$(mktemp -d)"
    hostname() { echo "test.example"; }
    host() { return 0; }                             # no hostname A records
    nftban_rbl_cache_get() { return 1; }             # force fresh path
    nftban_rbl_cache_set() { cat >/dev/null; }
    nftban_rbl_update_state() { :; }
    nftban_rbl_check_new_listing() { return 1; }
    nftban_rbl_send_alert() { :; }
    nftban_rbl_check_ip_parallel() { printf '%s\n' "$RESULTS"; }
    nftban_rbl_check_ip() { printf '%s\n' "$RESULTS"; }
    export -f hostname host nftban_rbl_cache_get nftban_rbl_cache_set nftban_rbl_update_state \
              nftban_rbl_check_new_listing nftban_rbl_send_alert nftban_rbl_check_ip_parallel nftban_rbl_check_ip
    local rc=0
    nftban_cmd_rbl_server check --fresh 2>&1 || rc=$?
    echo "RC=$rc"
  )
}

# T14 mixed clean + timeout => degraded verdict, never "All IPs are clean"
DEG=$'RBL Check Results for: 192.0.2.67\n⏱️  TIMEOUT: dnsbl.inps.de\nSummary:\n  Listed: 0\n  Clean: 21\n  Timeout: 1\n  Degraded total: 1 (RBL coverage incomplete — NOT fully verified)'
o="$(run_server "$DEG")"
{ has "$o" "NOT fully verified" && ! has "$o" "All IPs are clean (fully verified"; } && ok "T14 degraded verdict, no false 'All IPs are clean'" || no "T14 false-clean not fixed ($(echo "$o" | tail -3 | tr '\n' '|'))"
has "$o" "RC=2" && ok "T14b degraded rc=2" || no "T14b degraded rc not 2 ($(echo "$o" | tail -1))"

# T13 all-error => not clean, rc=2
ERR=$'RBL Check Results for: 192.0.2.67\n⏱️  ERROR: zen.spamhaus.org\nSummary:\n  Listed: 0\n  Clean: 0\n  Timeout: 1\n  Degraded total: 1 (RBL coverage incomplete — NOT fully verified)'
o="$(run_server "$ERR")"
{ ! has "$o" "All IPs are clean" && has "$o" "RC=2"; } && ok "T13 all-error => not clean, rc=2" || no "T13 all-error mishandled"

# fully-verified clean => allowed, rc=0
CLEAN=$'RBL Check Results for: 192.0.2.67\nSummary:\n  Listed: 0\n  Clean: 23\n  Timeout: 0'
o="$(run_server "$CLEAN")"
{ has "$o" "All IPs are clean (fully verified" && has "$o" "RC=0"; } && ok "fully-verified clean => rc=0 + clean verdict" || no "clean path wrong ($(echo "$o" | tail -2 | tr '\n' '|'))"

# listed => warning + rc=1
LISTED=$'RBL Check Results for: 192.0.2.67\nLISTED: zen.spamhaus.org\nSummary:\n  Listed: 1\n  Clean: 22'
o="$(run_server "$LISTED")"
{ has "$o" "on RBL blacklists" && has "$o" "RC=1"; } && ok "listed => warning + rc=1" || no "listed path wrong"

# ---------------------------------------------------------------------------
# Anti-duplication SOURCE guards
# ---------------------------------------------------------------------------
# G1: no new inline `ip … addr show` self-IP discovery in migrated RBL files
#     (allow only the documented fallback comment references; assert the live
#      discovery paths do not call `ip -[46] addr show` / `ip -o addr show`).
# strip comment lines (POSIX: [[:space:]], not \s) before pattern-hunting
strip_comments(){ grep -vE '^[[:space:]]*#'; }
guard_no_inline() {
  local f="$1"
  grep -nE 'ip +-[46o] +addr +show' "$f" 2>/dev/null | strip_comments | grep -viE 'legacy|fallback'
}
g="$(guard_no_inline "$RBL_CORE")$(guard_no_inline "$CMD_RBL")"
[[ -z "$g" ]] && ok "G1 no inline 'ip .. addr show' self-IP discovery in RBL files" || { no "G1 inline discovery remains"; echo "$g" | head; }

# G2: no $ip:ipv6 / :ipv4 colon-tag encoding in migrated RBL files (code, not comments)
g="$(grep -nE '\$ip:ipv6|\$ip:ipv4|:ipv6"|:ipv4"' "$CMD_RBL" "$RBL_CORE" 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#')"
[[ -z "$g" ]] && ok "G2 no \$ip:ipv6 colon-tag encoding" || { no "G2 colon-tag encoding present"; echo "$g" | head; }

# G3: RBL status + scheduled both consume the projection (get_public_ips)
grep -q 'nftban_rbl_get_public_ips' "$CMD_RBL" && grep -q 'nftban_rbl_get_public_ips' "$RBL_CORE" \
  && ok "G3 status + scheduled route through the projection" || no "G3 projection not shared"

# G4: no direct watchlist insertion from self-IP monitoring paths
g="$(grep -nE 'watchlist_add|watchlist.*>>|>> .*watchlist' "$CMD_RBL" | grep -iE 'self|monitor|discover|project_rbl')"
[[ -z "$g" ]] && ok "G4 no self-IP insertion into watchlist" || { no "G4 self-IP writes watchlist"; echo "$g"; }

# G5: authority is read-only (no nft/whitelist/state writes, no external IP fallback)
g="$(grep -nE 'nft (add|delete|flush)|ipify|icanhazip|curl|wget|> /|>> ' "$HOSTADDR" | grep -vE '^\s*#')"
[[ -z "$g" ]] && ok "G5 authority read-only (no nft/write/network)" || { no "G5 authority has side effects"; echo "$g"; }

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
