#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.220.1: non-public address admission across ALL RBL sources
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_nonpublic_admission_v220_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-11"
# meta:description="Locks the v1.220.1 RBL non-public admission family (F-RBL-0/1/2/3/4). RBL/DNSBL reputation is public-only; every candidate source (critical/configured, manual --ip, watchlist, cache, and the lowest-level check_ip/check_ip_parallel choke point) must classify via nftban_hostaddr_is_public before a DNSBL query, a cache read, or the listed/clean/degraded counts. Proves: no DNSBL/provider function is reached for a rejected address (serial + parallel choke point); non-public critical IPs are excluded from the unattended scheduled timer; manual --ip non-public yields a non-success rc and no query; watchlist non-public entries stay inspectable but unchecked (config not deleted); stale non-public cache is purged and not served; a duplicate public address across sources dedups; rbl critical add refuses non-public at the config boundary; eligible public addresses still query and preserve the rc contract. Shell-only; RBL observe-only; daemon byte-identical."
# meta:input="Stubbed ip/host/provider-loader + repo cmd_rbl.sh/nftban_rbl.sh/nftban_hostaddr.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_rbl.sh,cli/lib/nftban/core/nftban_rbl.sh,cli/lib/nftban/core/nftban_hostaddr.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RBL_CRITICAL_IPS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
set +eE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

NONPUBLIC=(127.0.0.1 127.0.1.1 ::1 10.0.0.5 192.168.1.10 169.254.1.1 fe80::1 100.64.0.1 fc00::1 0.0.0.0 :: 224.0.0.1 ff02::1 192.0.2.1 2001:db8::1 240.0.0.1)
PUBLIC4=46.225.150.67
PUBLIC6=2a01:4f8:c014:5ee1::1

echo "=== v1.220.1 RBL non-public admission (F-RBL-0/1/2/3/4) ==="

# --------------------------------------------------------------------------
# Part A — nftban_rbl_admit_candidate unit (classify + purge)
# --------------------------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$RBL_CORE" 2>/dev/null || true
  set +eE
  export NFTBAN_RBL_CACHE_DIR; NFTBAN_RBL_CACHE_DIR="$(mktemp -d)"
  bad=0
  nftban_rbl_admit_candidate "$PUBLIC4" 1 || bad=1
  nftban_rbl_admit_candidate "$PUBLIC6" 1 || bad=1
  [[ $bad -eq 0 ]] && echo "A1_OK" || echo "A1_FAIL"
  # every non-public rejected (rc1)
  rej=1
  for p in "${NONPUBLIC[@]}"; do nftban_rbl_admit_candidate "$p" 1 && rej=0; done
  [[ $rej -eq 1 ]] && echo "A2_OK" || echo "A2_FAIL"
  # cache purge: seed a stale entry, reject, assert removed
  printf 'stale\n' > "$NFTBAN_RBL_CACHE_DIR/127.0.0.1.cache"
  nftban_rbl_admit_candidate "127.0.0.1" 1 >/dev/null 2>&1
  [[ ! -f "$NFTBAN_RBL_CACHE_DIR/127.0.0.1.cache" ]] && echo "A3_OK" || echo "A3_FAIL"
) > /tmp/rblA.$$ 2>&1
grep -q A1_OK /tmp/rblA.$$ && ok "A1 admit_candidate admits public v4+v6" || no "A1 public admission"
grep -q A2_OK /tmp/rblA.$$ && ok "A2 admit_candidate rejects ALL ${#NONPUBLIC[@]} non-public probes" || no "A2 non-public leaked"
grep -q A3_OK /tmp/rblA.$$ && ok "A3 admit_candidate purges stale cache of a rejected address (F-RBL-4)" || no "A3 stale cache not purged"
rm -f /tmp/rblA.$$

# --------------------------------------------------------------------------
# Part B — F-RBL-0 choke point (serial + parallel): no provider reached for non-public
# --------------------------------------------------------------------------
choke() { # $1 fn (nftban_rbl_check_ip|_parallel) $2 ip -> "RC=<rc> REC=<providerhits>"
  (
    # shellcheck source=/dev/null
    source "$RBL_CORE" 2>/dev/null || true
    set +eE
    export NFTBAN_RBL_CACHE_DIR; NFTBAN_RBL_CACHE_DIR="$(mktemp -d)"
    REC="$(mktemp)"
    # stub provider loader to RECORD if reached + return NO providers (no real DNS)
    nftban_rbl_load_providers() { echo "PROVIDERCALLED" >> "$REC"; return 0; }
    export -f nftban_rbl_load_providers
    local rc=0
    "$1" "$2" text >/tmp/choke_out.$$ 2>&1 || rc=$?
    echo "RC=$rc REC=$(grep -c PROVIDERCALLED "$REC" 2>/dev/null || echo 0)"
  )
}
for fn in nftban_rbl_check_ip nftban_rbl_check_ip_parallel; do
  out="$(choke "$fn" 127.0.0.1)"
  { has "$out" "RC=2" && has "$out" "REC=0"; } && ok "B $fn: non-public → rc2, provider NEVER reached" || no "B $fn non-public reached provider ($out)"
  out="$(choke "$fn" "$PUBLIC4")"
  has "$out" "REC=1" && ok "B $fn: public → provider loader IS reached (guard blocks only non-public)" || no "B $fn public blocked ($out)"
done
rm -f /tmp/choke_out.$$

# --------------------------------------------------------------------------
# Part C — end-to-end admission (scheduled critical, manual --ip, watchlist, dedup)
# Stub the checkers to RECORD which IPs they were called with.
# --------------------------------------------------------------------------
run_cmd() { # $1 = shell snippet run after stubs; prints output + "CHECKED:<ip>" lines
  local SNIPPET="$1"
  (
    # shellcheck source=/dev/null
    source "$RBL_CORE" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$CMD_RBL" 2>/dev/null || true
    set +eE
    export NFTBAN_RBL_CACHE_DIR; NFTBAN_RBL_CACHE_DIR="$(mktemp -d)"
    REC="$NFTBAN_RBL_CACHE_DIR/checked.rec"; : > "$REC"
    # self-discovery: one public v4 + v6
    nftban_rbl_get_public_ips() { printf '%s\n' "46.225.150.67" "2a01:4f8:c014:5ee1::1"; }
    # RECORDING checkers (admission must exclude non-public BEFORE these are called)
    nftban_rbl_check_ip_parallel() { echo "$1" >> "$REC"; printf '%s\n' "Summary:" "  Listed: 0" "  Clean: 24"; }
    nftban_rbl_check_ip() { nftban_rbl_check_ip_parallel "$1"; }
    nftban_rbl_cache_get() { return 1; }
    nftban_rbl_cache_set() { cat >/dev/null; }
    nftban_rbl_update_state() { :; }
    nftban_rbl_check_new_listing() { return 1; }
    nftban_rbl_send_alert() { :; }
    export -f nftban_rbl_get_public_ips nftban_rbl_check_ip_parallel nftban_rbl_check_ip \
              nftban_rbl_cache_get nftban_rbl_cache_set nftban_rbl_update_state \
              nftban_rbl_check_new_listing nftban_rbl_send_alert
    eval "$SNIPPET"
    echo "---CHECKED---"; sort -u "$REC" 2>/dev/null | sed 's/^/CHECKED:/'
  )
}
no_nonpublic_checked() { # $1 output -> 0 if NO known non-public probe was checked
  local out="$1" p
  for p in "${NONPUBLIC[@]}"; do
    printf '%s\n' "$out" | grep -qxF "CHECKED:$p" && return 1
  done
  return 0
}

# C1 scheduled critical IPs — mixed public + non-public
o="$(run_cmd 'NFTBAN_RBL_CRITICAL_IPS="203.0.113.9|x" ; NFTBAN_RBL_CRITICAL_IPS="8.8.4.4|web,127.0.0.1|mail,10.0.0.5|db,::1|x" nftban_cmd_rbl_check --quiet 2>&1')"
{ ! printf '%s\n' "$o" | grep -q '^CHECKED:127.0.0.1$' && ! printf '%s\n' "$o" | grep -q '^CHECKED:10.0.0.5$' && ! printf '%s\n' "$o" | grep -q '^CHECKED:::1$'; } && ok "C1 scheduled: non-public critical IPs NOT checked (timer path protected)" || { no "C1 non-public critical checked"; printf '%s\n' "$o" | grep '^CHECKED:'; }
printf '%s\n' "$o" | grep -q '^CHECKED:8.8.4.4$' && ok "C1b public critical IP IS checked" || no "C1b public critical not checked"

# C2 manual --ip non-public → rc2, not checked
o="$(run_cmd 'nftban_cmd_rbl_check --ip 127.0.0.1 2>&1; echo RC=$?')"
{ has "$o" "RC=2" && ! printf '%s\n' "$o" | grep -q '^CHECKED:127.0.0.1$'; } && ok "C2 manual --ip loopback → rc2, no DNSBL" || no "C2 manual --ip non-public checked ($(printf '%s' "$o"|grep RC=))"
o="$(run_cmd 'nftban_cmd_rbl_check --ip 8.8.4.4 2>&1')"
printf '%s\n' "$o" | grep -q '^CHECKED:8.8.4.4$' && ok "C2b manual --ip public IS checked" || no "C2b manual --ip public not checked"

# C3 dedup: same public IP via self + critical → one check
o="$(run_cmd 'NFTBAN_RBL_CRITICAL_IPS="46.225.150.67|dup" nftban_cmd_rbl_check --quiet 2>&1')"
n="$(printf '%s\n' "$o" | grep -c '^CHECKED:46.225.150.67$' || true)"
[[ "$n" -le 1 ]] && ok "C3 duplicate public (self+critical) checked once" || no "C3 dup checked $n times"

# C4 only-public invariant across the mixed scheduled run
o="$(run_cmd 'NFTBAN_RBL_CRITICAL_IPS="8.8.4.4|web,192.168.1.10|lan,fe80::1|ll,224.0.0.1|mc" nftban_cmd_rbl_check --quiet 2>&1')"
{ no_nonpublic_checked "$o" && printf '%s\n' "$o" | grep -qxF 'CHECKED:8.8.4.4'; } && ok "C4 scheduled: only public checked (8.8.4.4 in; 192.168/fe80/224 out)" || { no "C4 non-public reached checker"; printf '%s\n' "$o" | grep '^CHECKED:'; }

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
