#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.220.1 hotfix: hostname-derived addresses must pass the shared
#          host-address classifier before entering the RBL candidate set
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_hostname_admission_v220_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-11"
# meta:description="Locks the v1.220.1 hostname-admission fix: nftban rbl server check must route every hostname-resolved address through nftban_hostaddr_is_public/scope (same classifier as self-interface IPs) before adding it to the RBL candidate set. Regression: v1.220.0 PR-B removed the per-IP private-skip guard while pre-filtering self-IPs via project_rbl, so a local resolver answering the hostname with 127.0.1.1 (loopback) was RBL-checked and 'Total IPs to check' was inflated. Asserts: loopback/private/link-local/unspecified hostname answers are EXCLUDED (shown with reason, not checked); public hostname answers are ADMITTED; a hostname answer equal to a self IP dedups to one; 'Total IPs to check' counts only admitted unique public addresses; zero eligible hostname answers => self-only. Shell-only; RBL observe-only; daemon byte-identical."
# meta:input="Stubbed ip/host + repo cmd_rbl.sh/nftban_rbl.sh/nftban_hostaddr.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_rbl.sh,cli/lib/nftban/core/nftban_rbl.sh,cli/lib/nftban/core/nftban_hostaddr.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

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
RBL_CORE="$NFTBAN_LIB_DIR/core/nftban_rbl.sh"
CMD_RBL="$NFTBAN_LIB_DIR/cli/cmd_rbl.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ [[ "$1" == *"$2"* ]]; }

# Self-interface fixture: eth0 (up) has one public v4 + one public v6; lo loopback.
# => project_rbl (self) = { 192.0.2.67, 2001:db8:c014:5ee1::1 } (2 addresses).
_ip_stub() {
  cat <<'STUB'
ip() {
  local j="$*"
  if [[ "$j" == *"link show up"* ]]; then
    printf '%s\n' "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536" "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"; return 0
  fi
  if [[ "$j" == *"-o addr show"* ]]; then
    printf '%s\n' \
      "1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever" \
      "1: lo    inet6 ::1/128 scope host \\       valid_lft forever preferred_lft forever" \
      "2: eth0    inet 192.0.2.67/24 scope global eth0\\       valid_lft forever preferred_lft forever" \
      "2: eth0    inet6 2001:db8:c014:5ee1::1/64 scope global \\       valid_lft forever preferred_lft forever"
    return 0
  fi
  return 0
}
export -f ip
STUB
}

# run_server <host-answer-lines> -> prints server-check output + RC=
# host-answer-lines: newline-separated "<hostname> has address <ip>" / "has IPv6 address <ip>"
run_server() {
  local HOSTOUT="$1"
  (
    # shellcheck source=/dev/null
    source "$RBL_CORE" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$CMD_RBL" 2>/dev/null || true
    set +eE
    eval "$(_ip_stub)"
    export NFTBAN_RBL_CACHE_DIR; NFTBAN_RBL_CACHE_DIR="$(mktemp -d)"
    hostname() { echo "host.example"; }
    host() { printf '%s\n' "$HOSTOUT"; }
    nftban_rbl_cache_get() { return 1; }
    nftban_rbl_cache_set() { cat >/dev/null; }
    nftban_rbl_cache_purge() { :; }
    nftban_rbl_update_state() { :; }
    nftban_rbl_check_new_listing() { return 1; }
    nftban_rbl_send_alert() { :; }
    # clean result for every checked IP
    nftban_rbl_check_ip_parallel() { printf '%s\n' "Summary:" "  Listed: 0" "  Clean: 24" "  Timeout: 0"; }
    nftban_rbl_check_ip() { nftban_rbl_check_ip_parallel; }
    export -f hostname host nftban_rbl_cache_get nftban_rbl_cache_set nftban_rbl_cache_purge \
              nftban_rbl_update_state nftban_rbl_check_new_listing nftban_rbl_send_alert \
              nftban_rbl_check_ip_parallel nftban_rbl_check_ip
    local rc=0
    nftban_cmd_rbl_server check --fresh 2>&1 || rc=$?
    echo "RC=$rc"
  )
}

total_line(){ printf '%s\n' "$1" | grep -oE 'Total IPs to check: [0-9]+' | grep -oE '[0-9]+' | head -1; }
checked(){ printf '%s\n' "$1" | grep -E '^Checking: ' | sed -E 's/^Checking: ([^ ]+).*/\1/'; }

echo "=== v1.220.1 hostname-admission classifier ==="

# 1. hostname -> 127.0.1.1 (IPv4 loopback) => excluded, not checked, Total=2 (self only)
o="$(run_server "host.example has address 127.0.1.1")"
{ has "$o" "127.0.1.1" && has "$o" "excluded from RBL checks"; } && ok "T1 loopback 127.0.1.1 shown + excluded" || no "T1 loopback not excluded/shown"
! printf '%s\n' "$o" | grep -qE '^Checking: 127\.0\.1\.1' && ok "T1b 127.0.1.1 NOT RBL-checked" || no "T1b 127.0.1.1 was checked"
[[ "$(total_line "$o")" == "2" ]] && ok "T1c Total IPs to check = 2 (self only)" || no "T1c Total wrong ($(total_line "$o"))"

# 2. hostname -> ::1 (IPv6 loopback) => excluded
o="$(run_server "host.example has IPv6 address ::1")"
{ has "$o" "excluded from RBL checks" && { ! printf '%s\n' "$o" | grep -qE '^Checking: ::1$'; }; } && ok "T2 ::1 excluded, not checked" || no "T2 ::1 mishandled"
[[ "$(total_line "$o")" == "2" ]] && ok "T2b Total = 2" || no "T2b Total wrong ($(total_line "$o"))"

# 3. hostname -> private IPv4 => excluded
o="$(run_server "host.example has address 10.0.0.5")"
{ has "$o" "excluded from RBL checks" && { ! printf '%s\n' "$o" | grep -qE '^Checking: 10\.0\.0\.5'; }; } && ok "T3 private IPv4 excluded" || no "T3 private IPv4 checked"

# 4. hostname -> link-local IPv6 => excluded
o="$(run_server "host.example has IPv6 address fe80::1")"
{ has "$o" "excluded from RBL checks" && { ! printf '%s\n' "$o" | grep -qE '^Checking: fe80::1'; }; } && ok "T4 link-local IPv6 excluded" || no "T4 link-local checked"

# 5. hostname -> the same public self IPv4 => admitted, deduped (Total stays 2)
o="$(run_server "host.example has address 192.0.2.67")"
[[ "$(total_line "$o")" == "2" ]] && ok "T5 hostname==self public dedups to one (Total=2)" || no "T5 dedup failed ($(total_line "$o"))"
[[ "$(checked "$o" | grep -c '^46\.225\.150\.67$')" == "1" ]] && ok "T5b self public checked exactly once" || no "T5b duplicate check"

# 6. hostname -> mixed public-new + loopback => only public admitted (Total=3)
o="$(run_server "$(printf '%s\n' 'host.example has address 8.8.8.8' 'host.example has address 127.0.1.1')")"
printf '%s\n' "$o" | grep -qE '^Checking: 8\.8\.8\.8' && ok "T6 new public hostname IP admitted+checked" || no "T6 public hostname IP not checked"
! printf '%s\n' "$o" | grep -qE '^Checking: 127\.0\.1\.1' && ok "T6b loopback still excluded in mixed set" || no "T6b loopback checked in mixed set"
[[ "$(total_line "$o")" == "3" ]] && ok "T6c Total = 3 (2 self + 1 admitted hostname)" || no "T6c Total wrong ($(total_line "$o"))"

# 7. zero eligible hostname answers => self-only (Total=2)
o="$(run_server "")"
[[ "$(total_line "$o")" == "2" ]] && ok "T7 zero hostname answers => self only (Total=2)" || no "T7 Total wrong ($(total_line "$o"))"

# 8. Total == count of admitted unique public 'Checking:' lines
o="$(run_server "host.example has address 127.0.1.1")"
nchecked="$(checked "$o" | grep -c .)"
[[ "$(total_line "$o")" == "$nchecked" ]] && ok "T8 Total == number of admitted Checking: lines ($nchecked)" || no "T8 Total($(total_line "$o")) != checked($nchecked)"

# 9. no legacy false-clean phrasing; degraded/clean verdict logic intact
o="$(run_server "host.example has address 127.0.1.1")"
{ ! has "$o" "All IPs are clean (not blacklisted)"; } && ok "T9 no legacy false-clean verdict" || no "T9 legacy verdict present"

# 10. GUARD: no bare hostname append without an is_public gate in cmd_rbl.sh
guardsrc="$(grep -n 'all_ips+=(.*hostname' "$CMD_RBL" 2>/dev/null || true)"
gate="$(awk '/Hostname-resolution leg/{f=1} f&&/nftban_hostaddr_is_public/{print "gated"; exit}' "$CMD_RBL")"
[[ -n "$guardsrc" && "$gate" == "gated" ]] && ok "T10 hostname admission gated by nftban_hostaddr_is_public" || no "T10 hostname admission not gated"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
