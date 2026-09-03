#!/usr/bin/env bash
# =============================================================================
# NFTBan - FULL-RULESET predicate sites must keep their UNKNOWN semantics
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="fullruleset-predicate-v1229-13-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Behavioural contract for the three FULL-RULESET sites converted in v1.229.13 Lane 2B-1a (_check_nft_collisions in cmd_firewall.sh, _nftban_portscan_verify_prefix in nftban_portscan_classic.sh, and the Check-1 ruleset probe in nftban_enable_all in service_control.sh). Each acquires an entire nft ruleset and then asks one boolean question of it. The conversion replaced ONLY that boolean; this test proves the OBSERVABLE OUTCOMES are unchanged across the three input classes that matter — command failure, rc=0 with whitespace-only output, and rc=0 with a real ruleset — because at these sites 'could not read' and 'read, and it was empty' must BOTH remain UNKNOWN rather than collapsing into a clean result. A fourth arm removes lib/shell_predicates.sh entirely and asserts identical outcomes, proving the declare -F fallback holds: without it an absent helper returns 127, the predicate evaluates FALSE, and a perfectly readable ruleset is silently reported UNKNOWN."
# meta:ta.id="fullruleset_predicate_v1229_13_test"
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
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/core/nftban_portscan_classic.sh,cli/lib/nftban/lib/service_control.sh,cli/lib/nftban/lib/shell_predicates.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== fullruleset_predicate_v1229_13 ==="

FW="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
PC="$ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh"
SC="$ROOT/cli/lib/nftban/lib/service_control.sh"
SP="$ROOT/cli/lib/nftban/lib/shell_predicates.sh"
for f in "$FW" "$PC" "$SC" "$SP"; do
    [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A realistic ruleset: whitespace-heavy, which is what made the replaced idiom costly.
REAL="$(awk 'BEGIN{print "table ip nftban {"; for(i=0;i<40;i++) printf "\t\tip saddr 10.0.0.%d counter drop\n", i; print "}"}')"

# ---------------------------------------------------------------------------
# Extract each subject function FROM SOURCE. Never retype it: the test must bind
# to the shipped code, so that editing the code and not the test is detectable.
# ---------------------------------------------------------------------------
extract_fn() {  # file, function name -> stdout
    awk -v fn="$2" '
        $0 ~ "^[[:space:]]*"fn"\\(\\)[[:space:]]*\\{" {d=1}
        d {print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if (depth<=0 && NR>1) exit}
    ' "$1"
}

# The loader block, taken verbatim from the subject file, so the arm that deletes
# lib/shell_predicates.sh exercises the REAL fallback rather than a copy of it.
extract_loader() { sed -n '/^declare -F nftban_has_non_whitespace/,+1p' "$1"; }

# ---------------------------------------------------------------------------
# ARM 1-3: outcomes for each input class, with the helper PRESENT.
# ARM 4: same, with lib/shell_predicates.sh ABSENT.
# ---------------------------------------------------------------------------
run_case() { # subject, nft_rc, nft_stdout, helper_present -> rc
    local subject="$1" nft_rc="$2" nft_out="$3" present="$4"
    local h="$WORK/h.sh"
    {
        echo 'set -uo pipefail'
        printf 'nft() { printf %%s "$NFT_OUT"; return %s; }\n' "$nft_rc"
        if [[ "$present" == "yes" ]]; then cat "$SP"; fi
        case "$subject" in
            fw) extract_loader "$FW"; echo 'json_mode=true'
                extract_fn "$FW" "_check_nft_collisions"; echo '_check_nft_collisions' ;;
            pc) extract_loader "$PC"
                echo '_nftban_portscan_classic_log() { :; }'
                extract_fn "$PC" "_nftban_portscan_verify_prefix"; echo '_nftban_portscan_verify_prefix' ;;
            sc) extract_loader "$SC"
                # Check 1 of nftban_enable_all, taken verbatim from source.
                sed -n '/# Check 1: nft rules loaded > 0/,/^    fi$/p' "$SC"
                echo 'printf "%s\n" "${validation_failures[*]:-}"' ;;
        esac
    } > "$h"
    NFT_OUT="$nft_out" bash "$h" 2>/dev/null >"$WORK/out.$subject"
    echo $?
}

for present in yes no; do
    label="helper $( [[ $present == yes ]] && echo PRESENT || echo ABSENT )"
    echo "--- $label ---"

    # ---- cmd_firewall.sh :: _check_nft_collisions ----
    rc=$(run_case fw 1 "" "$present")
    [[ "$rc" == 2 ]] && ok "[$label] fw: nft FAILS -> rc=2 (UNKNOWN, not 'no collisions')" \
                     || no "[$label] fw: nft failure gave rc=$rc, want 2"
    rc=$(run_case fw 0 "   
	  " "$present")
    [[ "$rc" == 2 ]] && ok "[$label] fw: rc=0 + whitespace-only -> rc=2 (UNKNOWN)" \
                     || no "[$label] fw: whitespace-only gave rc=$rc, want 2"
    rc=$(run_case fw 0 "$REAL" "$present")
    [[ "$rc" != 2 ]] && ok "[$label] fw: real ruleset -> parsed (rc=$rc, not UNKNOWN)" \
                     || no "[$label] fw: a READABLE ruleset was reported UNKNOWN"

    # ---- nftban_portscan_classic.sh :: _nftban_portscan_verify_prefix ----
    rc=$(run_case pc 1 "" "$present")
    [[ "$rc" == 2 ]] && ok "[$label] pc: nft FAILS -> rc=2 (prefix NOT verified)" \
                     || no "[$label] pc: nft failure gave rc=$rc, want 2"
    rc=$(run_case pc 0 "  
   " "$present")
    [[ "$rc" == 2 ]] && ok "[$label] pc: rc=0 + whitespace-only -> rc=2" \
                     || no "[$label] pc: whitespace-only gave rc=$rc, want 2"
    rc=$(run_case pc 0 "$REAL
	log prefix \"NFTBAN_PORTSCAN:\"" "$present")
    [[ "$rc" == 0 ]] && ok "[$label] pc: real ruleset with prefix -> rc=0 (verified)" \
                     || no "[$label] pc: readable ruleset gave rc=$rc, want 0"

    # ---- service_control.sh :: nftban_enable_all Check 1 ----
    run_case sc 1 "" "$present" >/dev/null
    grep -q 'UNKNOWN' "$WORK/out.sc" \
        && ok "[$label] sc: nft FAILS -> validation failure says UNKNOWN" \
        || no "[$label] sc: nft failure did not record UNKNOWN" "$(cat "$WORK/out.sc")"
    run_case sc 0 "    
  " "$present" >/dev/null
    grep -q 'UNKNOWN' "$WORK/out.sc" \
        && ok "[$label] sc: rc=0 + whitespace-only -> UNKNOWN (not '0 rules')" \
        || no "[$label] sc: whitespace-only did not record UNKNOWN" "$(cat "$WORK/out.sc")"
    run_case sc 0 "$REAL" "$present" >/dev/null
    grep -q 'UNKNOWN' "$WORK/out.sc" \
        && no "[$label] sc: a READABLE ruleset was reported UNKNOWN" \
        || ok "[$label] sc: real ruleset -> counted, not UNKNOWN"
done

echo "--- the replaced idiom is gone from these three sites ---"
for f in "$FW" "$PC" "$SC"; do
    b="$(basename "$f")"
    # v1.229.13 Lane 2B-3 converted the PER-SET sites too, once the shipped
    # template was shown to declare blacklist_ipv4 WITHOUT a size (unbounded,
    # feed-populated) and the cost was measured at 573 ms per call at 10k
    # entries and 14.0 s at 50k. Until then this asserted want=2 for
    # cmd_firewall.sh, which is why moving the boundary failed this test --
    # deliberately, so the scope change had to be argued rather than absorbed.
    want=0
    got="$(grep -c '//\[\[:space:\]\]/' "$f")"
    [[ "$got" == "$want" ]] && ok "$b: $got remaining copy-idiom site(s), as scoped" \
                            || no "$b: $got remaining copy-idiom site(s), expected $want"
done

echo
echo "=== fullruleset_predicate: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
