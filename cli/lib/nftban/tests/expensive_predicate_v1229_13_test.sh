#!/usr/bin/env bash
# =============================================================================
# NFTBan - the remaining expensive predicate sites keep their UNKNOWN semantics
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="expensive-predicate-v1229-13-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="expensive_predicate_v1229_13_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="shell-predicates"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="Behavioural contract for the four remaining sites converted in v1.229.13 Lane 2B: the cached nft -j ruleset probe in _doctor_gather_data, the per-table rule counter _nftban_count_rules, the inet-filter readability probe in nftban_health_check_nftables_security, and the chain-priority probe in nftban_detect_conflicting_tables. Each asks one boolean question of an acquired nft payload. Only that boolean changed; this proves the observable outcomes are unchanged across command failure, rc=0 with whitespace-only output, and rc=0 with real content — because at every one of these sites 'could not read' and 'read, and it was empty' must both remain UNKNOWN rather than collapsing into a measured fact. Sites are selected by MEASURED cost: on live hosts the full-ruleset and per-table payloads cost 0.4-2.3 s per call while per-set payloads show no measurable gain, so the per-set sites are deliberately NOT converted and this test pins that boundary."
# meta:inventory.files="cli/lib/nftban/core/nftban_config_doctor.sh,cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/core/nftban_health_checks_security.sh,cli/lib/nftban/core/nftban_firewall_conflicts.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== expensive_predicate_v1229_13 ==="

CD="$ROOT/cli/lib/nftban/core/nftban_config_doctor.sh"
CS="$ROOT/cli/lib/nftban/cli/cmd_status.sh"
HS="$ROOT/cli/lib/nftban/core/nftban_health_checks_security.sh"
FC="$ROOT/cli/lib/nftban/core/nftban_firewall_conflicts.sh"
SP="$ROOT/cli/lib/nftban/lib/shell_predicates.sh"
for f in "$CD" "$CS" "$HS" "$FC" "$SP"; do [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }; done
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

REAL="$(printf 'table ip nftban {\n\tchain input {\n\t\tip saddr 10.0.0.1 counter drop # handle 4\n\t}\n}\n')"
JSONREAL='{"nftables":[{"chain":{"family":"ip","table":"nftban","name":"input","prio":-10}}]}'

# Extract the exact block from source; never retype it.
blk(){ sed -n "$1" "$2"; }
loader(){ sed -n '/^declare -F nftban_has_non_whitespace/,+1p' "$1"; }
fn(){ awk -v f="$2" '$0 ~ "^[[:space:]]*"f"\\(\\)[[:space:]]*\\{"{d=1}
      d{print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if(depth<=0&&NR>1)exit}' "$1"; }

drive(){ # subject, nft_rc, nft_out, helper_present -> writes $WORK/out
    local subj="$1" rc="$2" out="$3" present="$4" h="$WORK/h.sh"
    {   echo 'set -uo pipefail'
        printf 'nft() { printf %%s "$NFT_OUT"; return %s; }\n' "$rc"
        [[ "$present" == yes ]] && cat "$SP"
        case "$subj" in
          cd) loader "$CD"
              # The extracted function references the file's severity constants;
              # take them FROM SOURCE so a renamed constant breaks the test too.
              grep -E '^readonly _SEV_' "$CD"
              echo '_doctor_finding(){ echo "FINDING:$2"; }'
              echo 'nftban_config_load_effective(){ echo "{}"; }'
              echo 'ss(){ :; }; systemctl(){ :; }'
              fn "$CD" "_doctor_gather_data"
              echo '_doctor_gather_data; echo "READABLE=$_DOCTOR_NFT_READABLE"' ;;
          cs) loader "$CS"; echo 'NFTBAN_TABLE_IPV4=nftban'
              fn "$CS" "_nftban_count_rules"; echo '_nftban_count_rules' ;;
          hs) loader "$HS"
              # The block uses `local`, so it must run inside a function.
              # HEALTH_* come from source; security_issues is the real array.
              # HEALTH_* are supplied by the health framework at runtime, not by
              # this file; every other test in the suite defines them inline, so
              # this follows that convention rather than inventing a new one.
              echo 'HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2; HEALTH_CRITICAL=3'
              echo 'security_issues=(); status=$HEALTH_OK'
              echo '_probe(){'
              blk '/local filter_policy _filter_raw _filter_readable=true/,/^        fi$/p' "$HS"
              echo '  echo "READABLE=$_filter_readable"'
              echo '}'
              echo '_probe' ;;
          fc) loader "$FC"
              echo 'jq(){ echo "-10"; }'
              blk '/local _prio_raw$/,/^    fi$/p' "$FC"
              echo 'echo "PRIO=$actual_nftban_prio"' ;;
        esac
    } > "$h"
    NFT_OUT="$out" bash "$h" 2>/dev/null > "$WORK/out"
}

for present in yes no; do
  lbl="helper $([[ $present == yes ]] && echo PRESENT || echo ABSENT)"
  echo "--- $lbl ---"

  # config_doctor: readable flag must be false on BOTH failure classes
  drive cd 1 ""            "$present"; grep -q 'READABLE=false' "$WORK/out" \
      && ok "[$lbl] doctor: nft FAILS -> NOT readable" || no "[$lbl] doctor: failure not flagged" "$(cat "$WORK/out")"
  drive cd 0 "   
 "  "$present"; grep -q 'READABLE=false' "$WORK/out" \
      && ok "[$lbl] doctor: rc=0 + whitespace-only -> NOT readable" || no "[$lbl] doctor: empty not flagged" "$(cat "$WORK/out")"
  drive cd 0 "$JSONREAL"   "$present"; grep -q 'READABLE=true' "$WORK/out" \
      && ok "[$lbl] doctor: real JSON -> readable" || no "[$lbl] doctor: readable JSON misflagged" "$(cat "$WORK/out")"

  # cmd_status: UNKNOWN must never be coerced to a number
  drive cs 1 ""          "$present"; grep -qx 'UNKNOWN' "$WORK/out" \
      && ok "[$lbl] count_rules: nft FAILS -> UNKNOWN" || no "[$lbl] count_rules: failure gave '$(cat "$WORK/out")'"
  drive cs 0 "  
	" "$present"; grep -qx 'UNKNOWN' "$WORK/out" \
      && ok "[$lbl] count_rules: rc=0 + whitespace-only -> UNKNOWN" || no "[$lbl] count_rules: empty gave '$(cat "$WORK/out")'"
  drive cs 0 "$REAL"     "$present"; grep -qx '1' "$WORK/out" \
      && ok "[$lbl] count_rules: real table -> 1 (counted, not UNKNOWN)" || no "[$lbl] count_rules: real gave '$(cat "$WORK/out")'"

  # health_checks_security: inet filter readability
  drive hs 1 ""          "$present"; grep -q 'READABLE=false' "$WORK/out" \
      && ok "[$lbl] health: nft FAILS -> filter NOT readable" || no "[$lbl] health: failure not flagged" "$(cat "$WORK/out")"
  drive hs 0 "     "     "$present"; grep -q 'READABLE=false' "$WORK/out" \
      && ok "[$lbl] health: rc=0 + whitespace-only -> NOT readable" || no "[$lbl] health: empty not flagged" "$(cat "$WORK/out")"
  drive hs 0 "$REAL"     "$present"; grep -q 'READABLE=true' "$WORK/out" \
      && ok "[$lbl] health: real table -> readable" || no "[$lbl] health: readable table misflagged" "$(cat "$WORK/out")"

  # firewall_conflicts: priority must stay UNKNOWN, never default to 0
  drive fc 1 ""          "$present"; grep -q 'PRIO=UNKNOWN' "$WORK/out" \
      && ok "[$lbl] conflicts: nft FAILS -> prio UNKNOWN (not 0)" || no "[$lbl] conflicts: failure gave '$(cat "$WORK/out")'"
  drive fc 0 "   "       "$present"; grep -q 'PRIO=UNKNOWN' "$WORK/out" \
      && ok "[$lbl] conflicts: rc=0 + whitespace-only -> prio UNKNOWN" || no "[$lbl] conflicts: empty gave '$(cat "$WORK/out")'"
  drive fc 0 "$JSONREAL" "$present"; grep -q 'PRIO=-10' "$WORK/out" \
      && ok "[$lbl] conflicts: real chain JSON -> prio parsed" || no "[$lbl] conflicts: real gave '$(cat "$WORK/out")'"
done

echo "--- scope boundary: PER-SET sites are deliberately NOT converted ---"
# Measured on live hosts: per-set payloads showed no gain (320-532us legacy vs
# 289-417us regex), while these four cost 0.4-2.3 s/call. The per-set payload
# scales with SET POPULATION, which is small on the measured hosts and unmeasured
# in production, so those sites are HELD rather than cleared.
held="$ROOT/cli/lib/nftban/core/nftban_health_checks_security.sh"
[[ "$(grep -c '//\[\[:space:\]\]/' "$held")" == 1 ]] \
    && ok "health_checks_security retains its 1 PER-SET site (boundary enforced)" \
    || no "per-set boundary drifted: $(grep -c '//\[\[:space:\]\]/' "$held") sites remain"
for f in "$CD" "$CS" "$FC"; do
    b="$(basename "$f")"; c="$(grep -c '//\[\[:space:\]\]/' "$f")"
    [[ "$c" == 0 ]] && ok "$b: fully converted" || no "$b: $c copy-idiom site(s) remain"
done

echo
echo "=== expensive_predicate: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
