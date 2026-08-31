#!/usr/bin/env bash
# =============================================================================
# NFTBan - the rebuild must be able to read back its own set serialisation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="blacklist-range-roundtrip-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="blacklist_ipv4/_ipv6 are declared `flags interval, timeout` with auto-merge, so the KERNEL merges adjacent bans and `nft list set` prints them as a-b. Rebuild step 7 restores from exactly that dump, and the parser's address pattern had no dash in its character class, so every merged element was skipped: NFTBan could not consume its own serialisation. MEASURED on lab2 through the genuine feed path — one rebuild took the set from 750 to 700 elements, 717 individual addresses silently stopped being blocked, and the only guard fires when the restored total is exactly ZERO so a partial loss was invisible. Production snapshot at the time: srv3 held 172 range-form elements covering ~840,483 addresses. Drives the REAL _fw_restore_timed_set with a stubbed nft, covers plain/CIDR/range for BOTH families plus mixed and malformed input, and reproduces the loss against the origin/main pattern so no row passes vacuously."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "${LIB_DIR}/../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/nft"; chmod +x "$T/bin/nft"
export PATH="$T/bin:$PATH"

# Extract ONLY the function under test from the real CLI, so the test binds to
# shipped code without executing the rest of the command surface.
sed -n '/^_fw_restore_timed_set()/,/^}/p' "${LIB_DIR}/cli/cmd_firewall.sh" > "$T/fn.sh"
[[ -s "$T/fn.sh" ]] || { echo "  [FAIL] could not extract _fw_restore_timed_set"; exit 1; }
# Build the pre-fix variant by STRIPPING the dash branch the fix added, then prove
# the result is byte-identical to the pattern origin/main actually shipped — so the
# control reproduces real historical behaviour rather than a retyped approximation.
sed 's|(-\[0-9a-fA-F:.\]+(/\[0-9\]{1,3})?)?||' "$T/fn.sh" > "$T/fn_old.sh"
if [[ "$(grep -c -- '-\[0-9a-fA-F' "$T/fn_old.sh")" -ne 0 ]]; then
    echo "  [FAIL] negative control still contains the dash branch — it would not reproduce the defect"; exit 1
fi
_stripped="$(grep -oE 'addr" =~ [^ ]+' "$T/fn_old.sh" | head -1)"
_shipped="$(git -C "$REPO" show origin/main:cli/lib/nftban/cli/cmd_firewall.sh 2>/dev/null \
            | grep -oE 'addr" =~ [^ ]+' | head -1)"
if [[ -n "$_shipped" && "$_stripped" == "$_shipped" ]]; then
    ok "negative control pattern is byte-identical to the one origin/main shipped"
else
    bad "control pattern does not match origin/main (stripped='$_stripped' shipped='$_shipped')"
fi

dump() { printf 'set x {\n  type ipv4_addr\n  elements = { %s }\n}\n' "$1" > "$T/d.txt"; }
run()  { # shellcheck source=/dev/null
         ( source "$T/${2:-fn.sh}" >/dev/null 2>&1; set +e
           _fw_restore_timed_set "$T/d.txt" "ip nftban" blacklist_ipv4 true ) }

echo "=== forms the kernel actually emits ==="
declare -A CASES=(
  ["plain IPv4"]="1.2.3.4"
  ["CIDR IPv4"]="1.2.3.0/24"
  ["RANGE IPv4 (kernel auto-merge output)"]="1.2.3.4-1.2.3.10"
  ["plain IPv6"]="2a00:1450::1"
  ["CIDR IPv6"]="2a00:1450::/48"
  ["RANGE IPv6 (kernel auto-merge output)"]="2a00:1450::1-2a00:1450::ff"
)
for label in "plain IPv4" "CIDR IPv4" "RANGE IPv4 (kernel auto-merge output)" \
             "plain IPv6" "CIDR IPv6" "RANGE IPv6 (kernel auto-merge output)"; do
    dump "${CASES[$label]}"
    read -r r s e <<<"$(run)"
    [[ "$r" == "1" && "$s" == "0" ]] && ok "$label: restored=$r skipped=$s" \
                                     || bad "$label: restored=$r skipped=$s expired=$e (want restored=1 skipped=0)"
done

echo "=== mixed serialisation in ONE dump (the real shape of a rebuild dump) ==="
dump "1.2.3.4, 1.2.3.0/24, 1.2.3.40-1.2.3.50, 10.0.0.1 timeout 1h expires 30m"
read -r r s e <<<"$(run)"
[[ "$r" == "4" && "$s" == "0" ]] && ok "mixed plain+CIDR+range+timed: restored=$r skipped=$s" \
                                 || bad "mixed dump: restored=$r skipped=$s expired=$e (want 4/0)"

echo "=== malformed forms are still rejected (the fix must not open the parser) ==="
for badform in "1.2.3.4-" "-1.2.3.4" "1.2.3.4-foo" "not-an-address!"; do
    dump "$badform"
    read -r r s e <<<"$(run)"
    [[ "$s" -ge 1 && "$r" == "0" ]] && ok "malformed '$badform' skipped (restored=$r skipped=$s)" \
                                    || bad "malformed '$badform' was ACCEPTED (restored=$r skipped=$s)"
done
echo "  (note: '1.2.3.4-foo' is rejected because 'foo' is not in the address class)"

echo "=== a SPACED range is not a form the kernel emits ==="
# MEASURED on lab4, nft v1.0.9: `nft list set` serialises a range as
# `5.80.0.1-5.80.0.9` — cat -A confirms no surrounding spaces. The parser splits
# the element on its first space to separate the address from `timeout .../expires
# ...`, so a hypothetical `a - b` would be read as the lower bound alone. That is a
# narrowing, but it is UNREACHABLE from a kernel dump, so it is documented here as
# behaviour rather than asserted as a defect. If a future nft ever spaces its range
# output, this row is where that assumption breaks.
dump "1.2.3.4 - 1.2.3.9"
read -r r s_ e <<<"$(run)"
[[ "$r" == "1" ]] \
    && ok "spaced 'a - b' yields the lower bound only (restored=$r) — unreachable from nft output, documented not asserted" \
    || bad "spaced form behaved unexpectedly: restored=$r skipped=$s_"

echo "=== malformed must not poison VALID entries in the same dump ==="
dump "1.2.3.4, 1.2.3.40-1.2.3.50, 1.2.3.4-foo, 9.9.9.9"
read -r r s e <<<"$(run)"
[[ "$r" == "3" && "$s" == "1" ]] && ok "valid entries survive alongside one malformed: restored=$r skipped=$s" \
                                 || bad "mixed valid/malformed: restored=$r skipped=$s (want 3/1)"

echo "=== ROUND TRIP: restore -> serialise -> restore is stable ==="
dump "1.2.3.4, 1.2.3.0/24, 1.2.3.40-1.2.3.50"
read -r r1 s1 _ <<<"$(run)"
read -r r2 s2 _ <<<"$(run)"
[[ "$r1" == "$r2" && "$s1" == "0" && "$s2" == "0" ]] \
    && ok "round trip stable: $r1 then $r2 restored, 0 skipped both times" \
    || bad "round trip drifted: $r1/$s1 then $r2/$s2"

echo "=== NEGATIVE CONTROL — origin/main pattern loses the range form ==="
for fam in "1.2.3.40-1.2.3.50:IPv4" "2a00:1450::1-2a00:1450::ff:IPv6"; do
    val="${fam%:*}"; name="${fam##*:}"
    dump "$val"
    read -r ro so _ <<<"$(run x fn_old.sh)"
    read -r rn sn _ <<<"$(run)"
    [[ "$ro" == "0" && "$so" == "1" && "$rn" == "1" && "$sn" == "0" ]] \
        && ok "$name range: origin/main restored=$ro skipped=$so -> fixed restored=$rn skipped=$sn" \
        || bad "$name control did not reproduce (old=$ro/$so new=$rn/$sn)"
done
dump "1.2.3.4, 1.2.3.0/24, 1.2.3.40-1.2.3.50"
read -r ro so _ <<<"$(run x fn_old.sh)"
read -r rn sn _ <<<"$(run)"
[[ "$ro" == "2" && "$rn" == "3" ]] \
    && ok "COVERAGE LOSS reproduced: origin/main restores $ro of 3, fixed restores $rn of 3" \
    || bad "coverage-loss control did not reproduce (old=$ro new=$rn)"

echo
echo "=== blacklist_range_roundtrip: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
