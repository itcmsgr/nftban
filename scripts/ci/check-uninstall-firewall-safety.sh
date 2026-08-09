#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="check-uninstall-firewall-safety"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="CI gate: package removal must NEVER leave an NFTBan base chain with policy drop and no accept rules. Rejects the flush-without-delete pattern in DEB/RPM maintainer scripts (the v1.221.2 uninstall-connectivity defect: nft flush table ip nftban kept the drop-policy input chain and locked out inbound SSH/ping until reboot)."
# meta:inventory.files=""
# meta:inventory.binaries="bash, awk, grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
FAIL=0

echo "========================================"
echo "NFTBan CI: Uninstall Firewall Safety (no drop-policy chain left after removal)"
echo "========================================"

# INVARIANT: in any package maintainer script, every
#   nft flush table (ip|ip6) nftban
# MUST be accompanied by a matching
#   nft delete table (ip|ip6) nftban
# within the same removal block (a few lines). A bare flush leaves the base
# `input` chain (policy drop) with zero accept rules → drops all inbound.
# Deleting the table removes the chain entirely → safe.
WINDOW=6

# check_flush_paired FILE  — returns non-zero if any nftban flush lacks a nearby delete.
check_flush_paired() {
    local f="$1" rc=0
    [ -f "$f" ] || return 0
    local n; n=$(wc -l < "$f")
    while IFS=: read -r ln fam; do
        [ -n "$ln" ] || continue
        # look for `nft delete table <fam> nftban` within the next WINDOW lines
        local end=$((ln + WINDOW))
        [ "$end" -gt "$n" ] && end="$n"
        if [[ "$(sed -n "${ln},${end}p" "$f" | grep -cE "nft delete table ${fam} nftban" || true)" -eq 0 ]]; then
            echo "::error::$f:$ln — 'nft flush table ${fam} nftban' has no matching 'nft delete table ${fam} nftban' within ${WINDOW} lines (would leave the ${fam} nftban input chain at policy drop with no accept rules → inbound lockout)"
            rc=1
        fi
    done < <(grep -nE "nft flush table (ip|ip6) nftban" "$f" | sed -E 's/^([0-9]+):.*nft flush table (ip6?|ip) nftban.*/\1:\2/')
    return $rc
}

# 1) DEB maintainer scripts.
for f in packaging/deb/postrm packaging/deb/prerm; do
    echo "[deb] $f"
    check_flush_paired "$f" || FAIL=1
done

# 2) RPM %postun (embedded in build_nftban.sh's spec generation).
echo "[rpm] packaging/build_nftban.sh (%postun/%preun)"
check_flush_paired "packaging/build_nftban.sh" || FAIL=1

# 3) Positive assertion: the DEB non-purge `remove)` path MUST delete the tables
#    (this is the exact path that was defective in <= v1.221.2).
echo "[remove-deletes] packaging/deb/postrm remove) case must delete tables"
remove_block="$(awk '/^[[:space:]]*remove\)/{p=1} p{print} p&&/;;/{exit}' packaging/deb/postrm)"
if grep -qE "nft delete table ip nftban" <<<"$remove_block" && grep -qE "nft delete table ip6 nftban" <<<"$remove_block"; then
    echo "  OK: remove) deletes ip + ip6 nftban tables"
else
    echo "::error::packaging/deb/postrm 'remove)' path does not delete ip/ip6 nftban tables — standard uninstall would leave a drop-policy chain (inbound lockout)"; FAIL=1
fi
if grep -qE "nft flush table ip nftban" <<<"$remove_block" && ! grep -qE "nft delete table ip nftban" <<<"$remove_block"; then
    echo "::error::packaging/deb/postrm 'remove)' flushes without deleting (the v1.221.2 defect)"; FAIL=1
fi

# 4) Negative self-test: a synthetic maintainer script that flushes without
#    deleting MUST be rejected by the guard.
_neg="$(mktemp)"
printf '%s\n' \
  'remove)' \
  '    if command -v nft >/dev/null 2>&1; then' \
  '        nft flush table ip nftban 2>/dev/null || true' \
  '        nft flush table ip6 nftban 2>/dev/null || true' \
  '        echo "flushed"' \
  '    fi' \
  '    ;;' > "$_neg"
if check_flush_paired "$_neg" >/dev/null 2>&1; then
    echo "::error::NEGATIVE SELF-TEST FAILED — guard did not reject a flush-without-delete maintainer script"; FAIL=1
else
    echo "  OK: negative self-test — guard rejects flush-without-delete"
fi
rm -f "$_neg"

echo "========================================"
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — no package-removal path leaves a drop-policy nftban chain"; exit 0; fi
echo "RESULT: FAIL — uninstall firewall-safety invariant violated (see ::error:: above)"; exit 1
