#!/usr/bin/env bash
# =============================================================================
# NFTBan - D8 verification compares live coverage against EFFECTIVE intent
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="dsr-effective-intent-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="The producer-attribution oracle must subtract the entries the single writer filters before comparing against the kernel. Measured on lab4 2026-08-31: a GeoBan source of two RFC 5737 ranges produced '[SYNC] CIDR filter: removed 2 problematic entries (bogon=2, oversized=0)' and an empty kernel set, so an oracle using RAW intent would report FAILED on a healthy host. Whitelist is deliberately NOT subtracted: six measured cases, including an exact whitelisted /32 banned with no covering range, showed the entry still committed — whitelist precedence is rule order (whitelist accept before blacklist drop), not set subtraction. Asserts the eight required cases: normal routable, bogon-only, mixed routable+bogon, oversized-only, mixed routable+oversized, full legitimate coverage, zero legitimate coverage, and idempotent repeat."
# meta:inventory.files="cli/lib/nftban/lib/derived_state_reconcile.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc/geoban.d" "$T/var/feeds"
export NFTBAN_CONFIG_DIR="$T/etc" NFTBAN_DATA_DIR="$T/var"
export PATH="$T/bin:$PATH"

# `nft` stub: LIVE_ELEMS is a JSON element array chosen per case.
cat > "$T/bin/nft" <<'EOS'
#!/bin/sh
printf '{"nftables":[{"set":{"family":"ip","name":"blacklist_ipv4","table":"nftban","elem":[%s]}}]}\n' "${LIVE_ELEMS:-}"
EOS
chmod +x "$T/bin/nft"
pfx() { printf '{"prefix":{"addr":"%s","len":%s}}' "$1" "$2"; }

# shellcheck source=/dev/null
source "${LIB_DIR}/lib/derived_state_reconcile.sh"
set +e

PLAN="producer=geoban
planned_state=RECONCILED"
run() { # $1=intent lines  $2=LIVE_ELEMS -> "<raw> <state> <rc>"
    printf '%s\n' "$1" > "$T/etc/geoban.d/50-ban-ZZ.conf"
    LIVE_ELEMS="$2" nftban_dsr_verify "$PLAN"
}
raw_of() { LIVE_ELEMS="" _nftban_dsr_intended_entries geoban 4 | grep -cE '[^[:space:]]'; }

echo "=== effective intent = raw - bogon - oversized ==="

# 1. normal routable CIDR, fully present
state="$(run '5.10.0.0/24' "$(pfx 5.10.0.0 24)")"
[[ "$state" == "RECONCILED" ]] && ok "normal routable CIDR fully present -> RECONCILED" || bad "normal routable -> $state"

# 2. bogon-only intent, nothing live. The daemon filters these, so they never
#    reach the kernel: zero coverage is CORRECT, not a failure.
state="$(run '203.0.113.0/24' "")"
[[ "$state" == "EMPTY" ]] && ok "bogon-only intent + empty kernel -> EMPTY (never FAILED)" \
                          || bad "bogon-only reported '$state' — a healthy host would be failed"

# 3. mixed routable + bogon: only the routable part is effective.
printf '5.10.0.0/24\n203.0.113.0/24\n' > "$T/etc/geoban.d/50-ban-ZZ.conf"
raw="$(raw_of)"
state="$(LIVE_ELEMS="$(pfx 5.10.0.0 24)" nftban_dsr_verify "$PLAN")"
[[ "$raw" -eq 2 ]] && ok "raw intent counts both entries ($raw)" || bad "raw intent = $raw, expected 2"
[[ "$state" == "RECONCILED" ]] \
    && ok "mixed routable+bogon, routable present -> RECONCILED (bogon not counted as missing)" \
    || bad "mixed routable+bogon -> $state (expected RECONCILED)"

# 4. oversized-only (prefix shorter than /9)
state="$(run '5.0.0.0/8' "")"
[[ "$state" == "EMPTY" ]] && ok "oversized-only (/8) + empty kernel -> EMPTY" || bad "oversized-only -> $state"

# 5. mixed routable + oversized
printf '5.10.0.0/24\n6.0.0.0/8\n' > "$T/etc/geoban.d/50-ban-ZZ.conf"
state="$(LIVE_ELEMS="$(pfx 5.10.0.0 24)" nftban_dsr_verify "$PLAN")"
[[ "$state" == "RECONCILED" ]] \
    && ok "mixed routable+oversized, routable present -> RECONCILED" \
    || bad "mixed routable+oversized -> $state (expected RECONCILED)"

# 6. full legitimate coverage across several routable ranges
printf '5.10.0.0/24\n5.20.0.0/24\n' > "$T/etc/geoban.d/50-ban-ZZ.conf"
state="$(LIVE_ELEMS="$(pfx 5.10.0.0 24),$(pfx 5.20.0.0 24)" nftban_dsr_verify "$PLAN")"
[[ "$state" == "RECONCILED" ]] && ok "full legitimate coverage -> RECONCILED" || bad "full coverage -> $state"

# 7. zero legitimate coverage — the measured GeoBan defect signature
state="$(run '5.10.0.0/24' "")"
rc=$?
[[ "$state" == "FAILED" ]] \
    && ok "routable intent with ZERO live coverage -> FAILED (the measured defect)" \
    || bad "zero coverage of effective intent -> $state (expected FAILED)"

# 8. partial coverage is still PARTIAL and still non-fatal
printf '5.10.0.0/24\n5.20.0.0/24\n' > "$T/etc/geoban.d/50-ban-ZZ.conf"
state="$(LIVE_ELEMS="$(pfx 5.10.0.0 24)" nftban_dsr_verify "$PLAN")"; rc=$?
[[ "$state" == "PARTIAL" && $rc -eq 0 ]] \
    && ok "half of effective intent present -> PARTIAL, non-fatal (rc=0)" \
    || bad "partial effective coverage -> $state rc=$rc"

# 9. idempotent repeat
printf '5.10.0.0/24\n' > "$T/etc/geoban.d/50-ban-ZZ.conf"
a="$(LIVE_ELEMS="$(pfx 5.10.0.0 24)" nftban_dsr_verify "$PLAN")"
b="$(LIVE_ELEMS="$(pfx 5.10.0.0 24)" nftban_dsr_verify "$PLAN")"
[[ "$a" == "$b" && "$a" == "RECONCILED" ]] && ok "repeated verification is idempotent ($a)" || bad "idempotence: $a then $b"

# 10. NEGATIVE CONTROL — prove the effective-intent subtraction is what carries
#     case 3, by asserting RAW intent would have produced a different verdict.
#     (raw=2 entries, only 1 present -> PARTIAL under a raw denominator)
printf '5.10.0.0/24\n203.0.113.0/24\n' > "$T/etc/geoban.d/50-ban-ZZ.conf"
raw_state="$(NFTBAN_DSR_BOGON_PREFIXES="" NFTBAN_DSR_MIN_PREFIX_LEN=0 \
             LIVE_ELEMS="$(pfx 5.10.0.0 24)" nftban_dsr_verify "$PLAN")"
[[ "$raw_state" == "PARTIAL" ]] \
    && ok "negative control: with filtering disabled the SAME input yields PARTIAL — the subtraction is load-bearing" \
    || bad "negative control did not discriminate (got '$raw_state'); case 3 may pass for the wrong reason"

echo
echo "=== dsr_effective_intent: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
