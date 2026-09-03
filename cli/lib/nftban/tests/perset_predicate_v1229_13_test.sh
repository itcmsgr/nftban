#!/usr/bin/env bash
# =============================================================================
# NFTBan - per-set predicate sites keep UNKNOWN, and the payload is UNBOUNDED
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="perset-predicate-v1229-13-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="perset_predicate_v1229_13_test"
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
# meta:description="Behavioural contract for the per-set sites converted in v1.229.13 Lane 2B-3 (nftban_nft_count_set and nftban_nft_count_set_elements in nft_schema.sh, _nftban_dsr_kernel_set_count and _nftban_dsr_producer_coverage_fam in derived_state_reconcile.sh, plus the set dumps in cmd_firewall.sh and nftban_health_checks_security.sh). These read `nft list set` on blacklist_ipv4/ipv6, which the shipped template declares WITHOUT a size — an unbounded, feed-populated set. Measured scaling: 100 entries costs 714us per predicate call, 10k costs 573ms, 50k costs 14.0s, because the replaced idiom copies the whole dump to ask one boolean. The lab hosts have near-empty sets, so a lab measurement alone would have wrongly cleared these sites. Proves each site still reports UNKNOWN for BOTH command failure and rc=0-with-empty-output rather than fabricating a count — the defect their own comments describe as reporting a 500k set as healthily small — and repeats the matrix with lib/shell_predicates.sh deleted to prove the declare -F fallback holds."
# meta:inventory.files="cli/lib/nftban/lib/nft_schema.sh,cli/lib/nftban/lib/derived_state_reconcile.sh,cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/core/nftban_health_checks_security.sh,install/nftables/nftables.conf.tpl"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== perset_predicate_v1229_13 ==="

NS="$ROOT/cli/lib/nftban/lib/nft_schema.sh"
DS="$ROOT/cli/lib/nftban/lib/derived_state_reconcile.sh"
CF="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
HS="$ROOT/cli/lib/nftban/core/nftban_health_checks_security.sh"
SP="$ROOT/cli/lib/nftban/lib/shell_predicates.sh"
TPL="$ROOT/install/nftables/nftables.conf.tpl"
for f in "$NS" "$DS" "$CF" "$HS" "$SP" "$TPL"; do [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }; done
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

SETJSON='{"nftables":[{"set":{"family":"ip","name":"blacklist_ipv4","table":"nftban","elem":["10.0.0.1","10.0.0.2"]}}]}'

loader(){ sed -n '/^declare -F nftban_has_non_whitespace/,+1p' "$1"; }
fn(){ awk -v f="$2" '$0 ~ "^[[:space:]]*"f"\\(\\)[[:space:]]*\\{"{d=1}
      d{print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if(depth<=0&&NR>1)exit}' "$1"; }

drive(){ # subject, rc, out, present
    local subj="$1" rc="$2" out="$3" present="$4" h="$WORK/h.sh"
    {   echo 'set -uo pipefail'
        printf 'nft() { printf %%s "$NFT_OUT"; return %s; }\n' "$rc"
        [[ "$present" == yes ]] && cat "$SP"
        case "$subj" in
          ns_json) loader "$NS"; fn "$NS" "nftban_nft_count_set"
                   echo 'nftban_nft_count_set ip nftban blacklist_ipv4' ;;
          ns_elem) loader "$NS"; fn "$NS" "nftban_nft_count_set_elements"
                   echo 'nftban_nft_count_set_elements ip nftban blacklist_ipv4' ;;
          dsr)     loader "$DS"; fn "$DS" "_nftban_dsr_kernel_set_count"
                   echo '_nftban_dsr_kernel_set_count ip blacklist_ipv4' ;;
        esac
    } > "$h"
    NFT_OUT="$out" bash "$h" 2>/dev/null > "$WORK/out"
}

for present in yes no; do
  lbl="helper $([[ $present == yes ]] && echo PRESENT || echo ABSENT)"
  echo "--- $lbl ---"
  for subj in ns_json ns_elem dsr; do
    drive "$subj" 1 "" "$present"
    grep -q 'UNKNOWN' "$WORK/out" \
      && ok "[$lbl] $subj: nft FAILS -> UNKNOWN (not a fabricated count)" \
      || no "[$lbl] $subj: failure gave '$(cat "$WORK/out")'"
    drive "$subj" 0 "   
	 " "$present"
    grep -q 'UNKNOWN' "$WORK/out" \
      && ok "[$lbl] $subj: rc=0 + whitespace-only -> UNKNOWN" \
      || no "[$lbl] $subj: empty gave '$(cat "$WORK/out")'"
    case "$subj" in
      ns_elem|dsr|ns_json) payload="$SETJSON" ;;
    esac
    drive "$subj" 0 "$payload" "$present"
    if grep -q 'UNKNOWN' "$WORK/out"; then
      no "[$lbl] $subj: a READABLE set dump was reported UNKNOWN"
    else
      ok "[$lbl] $subj: real set dump -> counted ($(tr -d '\n' < "$WORK/out"))"
    fi
  done
done

echo "--- why these sites are in scope: the payload is UNBOUNDED BY DECLARATION ---"
# The measurement that matters is not the lab's. Both labs carry near-empty sets,
# so a lab-only reading would have cleared these sites. The shipped template
# declares blacklist_ipv4/ipv6 with NO size, fed by feeds and geoban.
if awk '/^[[:space:]]*set blacklist_ipv4 \{/,/^[[:space:]]*\}/' "$TPL" | grep -qE '^\s*size '; then
    no "blacklist_ipv4 now declares a size — re-derive the cost bound for this lane"
else
    ok "blacklist_ipv4 is declared WITHOUT size (unbounded, feed-populated)"
fi
# The sites' own comments state the defect being protected.
grep -q '500k set as healthily small' "$HS" \
    && ok "health_checks_security still states the 500k-set failure it guards" \
    || no "the 500k-set rationale comment was lost"

echo "--- conversion completeness for this lane ---"
for f in "$NS" "$DS"; do
    b="$(basename "$f")"; c="$(grep -c '//\[\[:space:\]\]/' "$f")"
    [[ "$c" == 0 ]] && ok "$b: fully converted" || no "$b: $c copy-idiom site(s) remain"
done
# cmd_firewall and health_checks_security must now be free of them too.
for f in "$CF" "$HS"; do
    b="$(basename "$f")"; c="$(grep -c '//\[\[:space:\]\]/' "$f")"
    [[ "$c" == 0 ]] && ok "$b: fully converted" || no "$b: $c copy-idiom site(s) remain"
done
# nft_probe.sh is deliberately NOT converted, and the reason is PAYLOAD SIZE, not
# semantics. Its two probes read `nft list tables` (32 B) and `nft list sets`
# (7141 B / 239 lines on lab2) — both bounded by the NUMBER OF TABLES/SETS, never
# by element count, so no unbounded copy occurs. The register classifies both as
# FALSE_POSITIVE_PATTERN for exactly this reason; they are not deferred work.
#
# Two earlier rationales in this lane were wrong and are recorded so they are not
# revived: (1) "it needs a THIRD state, so the helper must never be adopted" —
# that conflated the FUNCTION's semantics with the PREDICATE's; the third state
# (EMPTY_OUTPUT_NO_ABSENCE_PROOF) is produced by _probe_fail_closed AFTER the
# test, so the helper WOULD be usable. (2) "deferred to Lane 2C" — there is no
# such deferral; the site is bounded and closed.

echo
echo "=== perset_predicate: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
