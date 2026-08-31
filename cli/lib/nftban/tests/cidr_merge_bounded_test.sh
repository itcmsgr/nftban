#!/usr/bin/env bash
# =============================================================================
# NFTBan - the O(n^2) CIDR fallback must be bounded, and must never half-convert
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="cidr-merge-bounded-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="D10. The pure-bash CIDR fallback compares every input against every CIDR kept so far. MEASURED on lab4 (EL9, where BOTH netmask and aggregate6 are absent so this IS the default path): 10->0.03s, 100->0.75s, 250->4.6s, 500->19.0s, 750->44.2s, 1000->76.5s, 1500->exceeded 120s; a real country zone (~3000 CIDRs) did not finish in 600s. Unbounded, that stalls a firewall rebuild for minutes with no verdict, which is worse than a truthful failure because a slow rebuild is indistinguishable from a hung one. The budget is NOT derived from the 600s failure: derived_state_reconcile.sh already governs a recovery apply with `timeout 120s nftban-core feeds load`, and a producer performs at most TWO converter invocations per apply (one per family), so 60s per converter makes the cumulative worst case exactly that same 120s. Asserts the bound fires, that NO partial conversion is ever emitted, that the caller sees a conversion FAILURE rather than an empty-but-successful result, and that normal small/medium input is unaffected."
# meta:inventory.files="cli/lib/nftban/lib/nftban_dataset_cidr.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; export PATH="$T/bin:$PATH"   # no netmask/aggregate6 -> bash path
# shellcheck source=/dev/null
source "${LIB_DIR}/lib/nftban_dataset_cidr.sh"
set +e
records() { local n; n="$(grep -cE '[^[:space:]]' "$1" 2>/dev/null)" || n="${n:-0}"; printf '%s' "${n:-0}"; }
gen() { python3 -c "
import sys,random
n=int(sys.argv[1]); random.seed(7)
seen=set()
while len(seen)<n:
    seen.add('%d.%d.%d.0/24' % (random.randint(1,223),random.randint(0,255),random.randint(0,255)))
print('\n'.join(sorted(seen)))" "$1" > "$2"; }

echo "=== the budget constant is declared and overridable ==="
[[ -n "${NFTBAN_CIDR_MERGE_BUDGET_SECONDS:-}" ]] \
    && ok "NFTBAN_CIDR_MERGE_BUDGET_SECONDS is defined (default ${NFTBAN_CIDR_MERGE_BUDGET_SECONDS})" \
    || bad "budget constant not defined"

echo "=== SUCCESS CONTROLS: the bound must not damage normal fallback operation ==="
for n in 5 50 200; do
    gen "$n" "$T/in.txt"
    NFTBAN_CIDR_MERGE_BUDGET_SECONDS=60 nftban_cidr_merge "$T/in.txt" "$T/out.txt" 4 >/dev/null 2>&1
    rc=$?
    got="$(records "$T/out.txt")"
    [[ $rc -eq 0 && "$got" -eq "$n" ]] \
        && ok "$n CIDRs convert normally inside the budget (rc=0, $got out)" \
        || bad "$n CIDRs: rc=$rc output=$got (want rc=0 and $n)"
done

echo "=== IPv6 fallback still works under the bound ==="
printf '2a00:1450:4001::/48\n2a00:1450:4002::/48\n' > "$T/v6.txt"
NFTBAN_CIDR_MERGE_BUDGET_SECONDS=60 nftban_cidr_merge "$T/v6.txt" "$T/out6.txt" 6 >/dev/null 2>&1
[[ $? -eq 0 && "$(records "$T/out6.txt")" -eq 2 ]] && ok "IPv6 fallback unaffected by the budget" \
                                                   || bad "IPv6 fallback broken under the budget"

echo "=== THE BOUND FIRES on a workload that cannot finish in time ==="
gen 1200 "$T/big.txt"
start=$(date +%s)
NFTBAN_CIDR_MERGE_BUDGET_SECONDS=2 nftban_cidr_merge "$T/big.txt" "$T/bigout.txt" 4 >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
[[ $rc -ne 0 ]] && ok "budget exhausted -> conversion FAILS (rc=$rc), never a false success" \
                || bad "budget exhausted but conversion returned success (rc=$rc)"
[[ "$elapsed" -le 20 ]] && ok "terminated promptly (${elapsed}s) instead of running to completion" \
                        || bad "did not terminate promptly: ${elapsed}s"

echo "=== ⛔ NO PARTIAL CONVERSION IS EVER EMITTED ==="
got="$(records "$T/bigout.txt")"
[[ "$got" -eq 0 ]] \
    && ok "output is EMPTY after a timed-out conversion — no half-converted country can be applied" \
    || bad "timed-out conversion left $got records behind; a caller ignoring rc would apply a partial set"

echo "=== the caller sees FAILURE, not an empty success ==="
# nftban_cidr_merge's contract: rc!=0 means the caller must not apply. The
# fail-closed callers added in this lane refuse to apply on exactly that signal.
NFTBAN_CIDR_MERGE_BUDGET_SECONDS=2 nftban_cidr_merge "$T/big.txt" "$T/o2.txt" 4 >/dev/null 2>&1
[[ $? -ne 0 && "$(records "$T/o2.txt")" -eq 0 ]] \
    && ok "conversion failure is distinguishable from 'this source has no ranges'" \
    || bad "a timed-out conversion is indistinguishable from an empty source"

echo "=== ⛔ there is NO config path back to an unbounded conversion ==="
# Two separate proofs, because timing a backgrounded subshell proved unreliable:
# an earlier version of this test polled a background PID and reported 1s for runs
# that actually took 65s, which would have passed vacuously.
#
# (a) RESOLUTION — deterministic, no timing involved.
for badval in 0 "" abc -5 " " 3.5; do
    got="$( NFTBAN_CIDR_MERGE_BUDGET_SECONDS="$badval" \
            bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$NFTBAN_CIDR_MERGE_BUDGET_SECONDS"' \
                 _ "${LIB_DIR}/lib/nftban_dataset_cidr.sh" )"
    [[ "$got" == "60" ]] \
        && ok "budget='$badval' resolves to the default 60, not to 'unlimited'" \
        || bad "budget='$badval' resolved to '$got' — a config path away from the bound"
done

# (b) BEHAVIOUR — one full-speed run at the real default, measured in the
#     foreground. 1200 CIDRs needs ~100s unbounded on this class of hardware, so a
#     bounded run must stop near 60s and emit nothing.
gen 1200 "$T/u.txt"
start=$(date +%s)
NFTBAN_CIDR_MERGE_BUDGET_SECONDS=0 timeout 150 bash -c '
    source "$1" >/dev/null 2>&1; set +e
    nftban_cidr_merge "$2" "$3" 4 >/dev/null 2>&1; exit $?' \
    _ "${LIB_DIR}/lib/nftban_dataset_cidr.sh" "$T/u.txt" "$T/uo.txt"
rc=$?; elapsed=$(( $(date +%s) - start ))
[[ $rc -ne 0 && $rc -ne 124 ]] \
    && ok "budget=0 still terminates by the DEFAULT bound (rc=$rc, ${elapsed}s), not unbounded" \
    || bad "budget=0 run rc=$rc after ${elapsed}s (124 = ran to the outer 150s cap = unbounded)"
[[ "$elapsed" -ge 30 && "$elapsed" -le 110 ]] \
    && ok "stopped in the expected window (${elapsed}s) — the bound fired, it did not finish early" \
    || bad "elapsed ${elapsed}s is outside the window; the row may be passing for the wrong reason"
[[ "$(records "$T/uo.txt")" -eq 0 ]] \
    && ok "no partial output from the default-bounded run" \
    || bad "partial output left behind"

echo
echo "=== cidr_merge_bounded: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
