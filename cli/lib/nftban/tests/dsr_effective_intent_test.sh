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

echo "=== an UNREADABLE source is not an EMPTY one ==="
# A present-but-unreadable durable source must not read as "no effective intent".
# That would render a quiet non-result as a decision — the UNKNOWN-as-zero shape.
if [[ "$(id -u)" -eq 0 ]]; then
    ok "SKIPPED as root (chmod 000 does not restrict root) — asserted under an unprivileged run"
else
    printf '5.10.0.0/24\n' > "$T/etc/geoban.d/50-ban-ZZ.conf"
    chmod 000 "$T/etc/geoban.d/50-ban-ZZ.conf"
    st="$(LIVE_ELEMS="" nftban_dsr_verify "$PLAN")"
    chmod 644 "$T/etc/geoban.d/50-ban-ZZ.conf"
    [[ "$st" == "UNKNOWN" ]] \
        && ok "present but unreadable source -> UNKNOWN (not EMPTY, not FAILED)" \
        || bad "unreadable source reported '$st' — a non-result presented as a decision"
fi

echo "=== CROSS-FAMILY: no family may license success for the other ==="
# Family-aware stub: the ip query and the ip6 query must answer differently, or
# the test could not tell the families apart at all.
cat > "$T/bin/nft" <<'EOS'
#!/bin/sh
for a in "$@"; do case "$a" in ip6) fam=6 ;; ip) fam=${fam:-4} ;; esac; done
if [ "${fam:-4}" = "6" ]; then
  printf '{"nftables":[{"set":{"family":"ip6","name":"blacklist_ipv6","table":"nftban","elem":[%s]}}]}\n' "${LIVE6:-}"
else
  printf '{"nftables":[{"set":{"family":"ip","name":"blacklist_ipv4","table":"nftban","elem":[%s]}}]}\n' "${LIVE4:-}"
fi
EOS
chmod +x "$T/bin/nft"
p6() { printf '{"prefix":{"addr":"%s","len":%s}}' "$1" "$2"; }
famrun() { # $1=intent lines $2=LIVE4 $3=LIVE6
    printf '%s\n' "$1" > "$T/etc/geoban.d/50-ban-ZZ.conf"
    # ⛔ EXPORT, do not prefix. `VAR=x somefunc` does not reliably reach the child
    #    processes the function spawns — the same trap that left the bogon list
    #    empty when the assignment was written before `printf` instead of before
    #    `python3`. The stub `nft` is a child, so the values must be exported.
    export LIVE4="$2" LIVE6="$3"
    nftban_dsr_verify "$PLAN"
}
V4="5.10.0.0/24"; V6="2a00:1450:4001::/48"
e4="$(pfx 5.10.0.0 24)"; e6="$(p6 2a00:1450:4001:: 48)"

st="$(famrun "$V4" "$e4" "")"
[[ "$st" == "RECONCILED" ]] && ok "IPv4-only intent, IPv4 present -> RECONCILED" || bad "v4-only -> $st"
st="$(famrun "$V6" "" "$e6")"
[[ "$st" == "RECONCILED" ]] && ok "IPv6-only intent, IPv6 present -> RECONCILED (v6 intent is no longer invisible)" || bad "v6-only -> $st"
st="$(famrun "$V4
$V6" "$e4" "$e6")"
[[ "$st" == "RECONCILED" ]] && ok "dual-stack, both present -> RECONCILED" || bad "dual-stack both -> $st"
st="$(famrun "$V4
$V6" "$e4" "")"
[[ "$st" == "FAILED" ]] && ok "dual-stack, IPv4 present / IPv6 ABSENT -> FAILED (v4 cannot license v6)" \
                        || bad "v4-present/v6-absent -> $st (expected FAILED)"
st="$(famrun "$V4
$V6" "" "$e6")"
[[ "$st" == "FAILED" ]] && ok "dual-stack, IPv6 present / IPv4 ABSENT -> FAILED (v6 cannot license v4)" \
                        || bad "v6-present/v4-absent -> $st (expected FAILED)"
# Restore the single-family stub for any later rows.
cat > "$T/bin/nft" <<'EOS'
#!/bin/sh
printf '{"nftables":[{"set":{"family":"ip","name":"blacklist_ipv4","table":"nftban","elem":[%s]}}]}\n' "${LIVE_ELEMS:-}"
EOS
chmod +x "$T/bin/nft"

echo
echo "=== dsr_effective_intent: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
