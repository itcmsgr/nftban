#!/usr/bin/env bash
# =============================================================================
# NFTBan - RBLMON enable-readiness hardening (§4.2 state.dat prune + §4.3 advisory)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_enable_readiness_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-08"
# meta:description="§4.2 nftban_rbl_prune_state bounds state.dat to the live monitored IP set — stale IPs removed, still-monitored IPs retained VERBATIM (transition baseline preserved), empty set is a NO-OP, comments kept. §4.3 nftban_health_check_rbl surfaces a config advisory (WARN) when RBL is ENABLED but has no effective watch targets (auto-discover OFF + no critical IPs + empty watchlist), config-only, observe-only wording, never a silent CLEAN, never a firewall hard-fail. Hermetic: extracted fns, no DNSBL/network, no real mail, no nft writes."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_RBL_CACHE_DIR,NFTBAN_RBL_AUTO_DISCOVER_IPS,NFTBAN_RBL_CRITICAL_IPS,NFTBAN_RBL_WATCHLIST_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
RBL="$REPO/cli/lib/nftban/core/nftban_rbl.sh"
MODULES="$REPO/cli/lib/nftban/core/nftban_health_checks_modules.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== RBLMON enable-readiness (§4.2 prune + §4.3 advisory) ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ §4.2 age-based prune
PFN="$WORK/prune.sh"
awk '/^nftban_rbl_prune_state\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RBL" > "$PFN"

prune_run() {  # $1 = state.dat contents ; $2 = TTL seconds (default 30d)
  local content="$1" ttl="${2:-2592000}"
  bash -c '
    set +e
    export NFTBAN_RBL_CACHE_DIR="'"$WORK"'/cache"; mkdir -p "$NFTBAN_RBL_CACHE_DIR"
    export NFTBAN_RBL_STATE_TTL="'"$ttl"'"
    _nftban_rbl_state_to_json() { :; }   # stub: json regen not under test
    printf '"'"'%s'"'"' "'"$content"'" > "$NFTBAN_RBL_CACHE_DIR/state.dat"
    source "'"$PFN"'"
    nftban_rbl_prune_state
    cat "$NFTBAN_RBL_CACHE_DIR/state.dat"
  '
}

# real timestamps: FRESH = now (refreshed this scan), STALE = 40d ago (past the 30d retention)
NOW=$(date -Iseconds); OLD=$(date -Iseconds -d '40 days ago'); MID=$(date -Iseconds -d '5 days ago')
SD=$'# rbl state\n'"A=listed|$NOW|clean|$OLD"$'\n'"B=clean|$OLD|clean|$OLD"$'\n'"C=clean|$MID||"$'\n'

# 1. fresh line retained, stale line pruned (age-based core)
r=$(prune_run "$SD")
echo "$r" | grep -q '^A=' && ! echo "$r" | grep -q '^B=' && ok "§4.2 fresh(A) retained, stale-40d(B) pruned" || no "4.2-1: $r"

# 2. currently-refreshed IP line preserved VERBATIM (transition baseline byte-identical)
r=$(prune_run "$SD")
echo "$r" | grep -qxF "A=listed|$NOW|clean|$OLD" && ok "§4.2 refreshed A line byte-identical (baseline not reset)" || no "4.2-2: $r"

# 3. transiently-missing-but-not-expired IP (C, 5d old, absent from any 'set') RETAINED
r=$(prune_run "$SD")
echo "$r" | grep -q '^C=' && ok "§4.2 transiently-absent-but-fresh(C 5d) retained (age-based, not set-membership)" || no "4.2-3: $r"

# 4. malformed timestamp -> KEEP (never prune on ambiguity)
r=$(prune_run $'X=listed|not-a-date|clean|t0\n')
echo "$r" | grep -q '^X=' && ok "§4.2 unparseable timestamp -> line KEPT (no prune on ambiguity)" || no "4.2-4: $r"

# 5. comments/blank kept verbatim
r=$(prune_run "$SD")
echo "$r" | grep -qxF '# rbl state' && ok "§4.2 comment line kept verbatim" || no "4.2-5: $r"

# 6. non-numeric / zero TTL -> keep everything (fail-safe, no pruning)
r=$(prune_run "$SD" 0)
echo "$r" | grep -q '^A=' && echo "$r" | grep -q '^B=' && echo "$r" | grep -q '^C=' && ok "§4.2 TTL=0 disables pruning (fail-safe keep-all)" || no "4.2-6: $r"
r=$(prune_run "$SD" abc)
echo "$r" | grep -q '^B=' && ok "§4.2 non-numeric TTL disables pruning (fail-safe keep-all)" || no "4.2-6b: $r"

# 7. NO set-membership behaviour remains: passing IP args must NOT change the outcome (age-based only)
awk_args=$(grep -c '_keep\|for _ip in' "$PFN" || true)
[[ "$awk_args" -eq 0 ]] && ok "§4.2 no set-membership code remains (no _keep / IP-arg loop)" || no "4.2-7: set-membership residue ($awk_args)"

# 8. empty current enumeration does NOT wipe state.dat (age-based ignores enumeration entirely)
r=$(prune_run $'A=listed|'"$NOW"'|clean|'"$OLD"$'\n')
echo "$r" | grep -q '^A=' && ok "§4.2 fresh entry survives regardless of enumeration (no set input)" || no "4.2-8: $r"

# 9. no transition-baseline reset: a just-updated IP (now) is never pruned even at tiny TTL=1s
r=$(prune_run $'A=listed|'"$NOW"'|clean|'"$OLD"$'\n' 1)
echo "$r" | grep -qxF "A=listed|$NOW|clean|$OLD" && ok "§4.2 just-refreshed IP survives even at TTL=1s (fresh never pruned)" || no "4.2-9: $r"

# 10. TTL FLOOR: a mis-set tiny TTL (1h) must NOT prune a still-live cache-served IP (~20h old);
#     the floor (max 48h, 2x cache-TTL) clamps the window up so live cache-served IPs survive.
H20=$(date -Iseconds -d '20 hours ago')
r=$(prune_run $'A=listed|'"$H20"'|clean|'"$OLD"$'\n' 3600)
echo "$r" | grep -q '^A=' && ok "§4.2 TTL floor: 20h-old live IP retained under mis-set 1h TTL (floor≥48h)" || no "4.2-10: $r"

# 11. floor still prunes GENUINE staleness: a 40d entry is older than the 48h floor -> pruned
r=$(prune_run $'B=clean|'"$OLD"'|clean|'"$OLD"$'\n' 3600)
! echo "$r" | grep -q '^B=' && ok "§4.2 floor still prunes genuinely-stale 40d entry (>48h)" || no "4.2-11: $r"

# ------------------------------------------------------------------ §4.3 advisory
HFN="$WORK/hrbl.sh"
awk '/^nftban_health_check_rbl\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" > "$HFN"

hrbl() {  # env-var assignments as $1 (conf lines), returns "CODE=n" + issue text
  bash -c '
    set +e
    export NFTBAN_CONFIG_DIR="'"$WORK"'/etc" NFTBAN_LOG_DIR="'"$WORK"'/log"
    mkdir -p "$NFTBAN_CONFIG_DIR/conf.d/rbl" "$NFTBAN_LOG_DIR/rbl"
    HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2
    declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES; declare -a NFTBAN_HEALTH_ERRORS
    systemctl() { return 1; }   # skip timer sub-check (is-enabled fails)
    date -Iseconds > "$NFTBAN_LOG_DIR/rbl/last_check"   # recent -> no stale WARN
    unset NFTBAN_RBL_AUTO_DISCOVER_IPS NFTBAN_RBL_CRITICAL_IPS NFTBAN_RBL_WATCHLIST_FILE
    '"$1"'
    source "'"$HFN"'"
    nftban_health_check_rbl; c=$?; echo "CODE=$c"; printf "%s\n" "${NFTBAN_HEALTH_ISSUES[rbl]}"
  '
}

CONF='printf "NFTBAN_RBL_ENABLED=\"YES\"\n" > "$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf"'

# A. enabled + auto-discover OFF + no critical + no watchlist -> WARN advisory
r=$(hrbl "$CONF; printf 'NFTBAN_RBL_AUTO_DISCOVER_IPS=\"NO\"\n' >> \"\$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'no watch targets' && ok "§4.3 enabled + no effective targets -> WARN advisory (not silent CLEAN)" || no "4.3-A: $r"

# A-wording. observe-only framing preserved, not firewall-failure
echo "$r" | grep -q 'not firewall blocking' && ok "§4.3 advisory preserves observe-only wording" || no "4.3-Aw: $r"

# A-severity. WARN not ERROR (never hard-fail posture)
echo "$r" | grep -q 'CODE=1' && ! echo "$r" | grep -q 'CODE=2' && ok "§4.3 severity is WARN, never ERROR" || no "4.3-Asev: $r"

# B. enabled + auto-discover YES (default) -> no empty-watchlist advisory
r=$(hrbl "$CONF")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'no watch targets' && ok "§4.3 enabled + auto-discover YES -> no empty-watchlist WARN" || no "4.3-B: $r"

# C. enabled + auto-discover OFF + CRITICAL_IPS set -> no advisory
r=$(hrbl "$CONF; printf 'NFTBAN_RBL_AUTO_DISCOVER_IPS=\"NO\"\nNFTBAN_RBL_CRITICAL_IPS=\"203.0.113.5\"\n' >> \"\$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf\"")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'no watch targets' && ok "§4.3 auto-discover OFF but CRITICAL_IPS set -> no advisory" || no "4.3-C: $r"

# D. enabled + auto-discover OFF + non-empty watchlist file -> no advisory
r=$(hrbl "printf '203.0.113.9\n' > \"\$NFTBAN_LOG_DIR/wl.txt\"; $CONF; printf 'NFTBAN_RBL_AUTO_DISCOVER_IPS=\"NO\"\nNFTBAN_RBL_WATCHLIST_FILE=\"'\"\$NFTBAN_LOG_DIR\"'/wl.txt\"\n' >> \"\$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf\"")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'no watch targets' && ok "§4.3 auto-discover OFF but non-empty watchlist -> no advisory" || no "4.3-D: $r"

# E. disabled -> OK, no advisory (early return)
r=$(hrbl 'printf "NFTBAN_RBL_ENABLED=\"NO\"\n" > "$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf"')
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'no watch targets' && ok "§4.3 disabled -> OK, no empty-watchlist WARN" || no "4.3-E: $r"

# F. auto-discover OFF + watchlist file present but comments-only -> WARN (empty effective)
r=$(hrbl "printf '# only a comment\n' > \"\$NFTBAN_LOG_DIR/wl.txt\"; $CONF; printf 'NFTBAN_RBL_AUTO_DISCOVER_IPS=\"NO\"\nNFTBAN_RBL_WATCHLIST_FILE=\"'\"\$NFTBAN_LOG_DIR\"'/wl.txt\"\n' >> \"\$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'no watch targets' && ok "§4.3 comments-only watchlist counts as empty -> WARN" || no "4.3-F: $r"

# G. STRICT MODE (set -eEuo pipefail, NO `|| true` caller wrap): enabled + no env vars, main.conf has
#    no watchlist line → the grep fallbacks must NOT abort the function mid-body (deputy-2 finding).
r=$(bash -c '
  set -eEuo pipefail
  export NFTBAN_CONFIG_DIR="'"$WORK"'/etcs" NFTBAN_LOG_DIR="'"$WORK"'/logs"
  mkdir -p "$NFTBAN_CONFIG_DIR/conf.d/rbl" "$NFTBAN_LOG_DIR/rbl"
  HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2
  declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES; declare -a NFTBAN_HEALTH_ERRORS
  systemctl() { return 1; }
  date -Iseconds > "$NFTBAN_LOG_DIR/rbl/last_check"
  printf "NFTBAN_RBL_ENABLED=\"YES\"\n" > "$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf"
  source "'"$HFN"'"
  nftban_health_check_rbl; c=$?
  echo "DONE=$c RESULT=${NFTBAN_HEALTH_RESULTS[rbl]:-UNSET}"
' 2>&1 || echo "ABORTED")
echo "$r" | grep -q 'DONE=' && echo "$r" | grep -q 'RESULT=0' && ! echo "$r" | grep -q 'ABORTED' && ok "§4.3 completes under strict mode without || true (grep fallbacks guarded)" || no "4.3-G strict: $r"

# ------------------------------------------------------------------ regressions
o=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 ); echo "$o" | grep -q '0/4 DEBT' && ok "A0 guard 0/4" || no "A0 guard regressed"
echo "  RBL nft/ban writes: $(grep -cE 'nft add|nftban_ban|add element' "$RBL")  (want 0)"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
