#!/usr/bin/env bash
# =============================================================================
# NFTBan - VERSION_DATE coherence guard (v1.228.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-version-date-coherence"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="BLOCKING. VERSION_DATE is the operator-visible Release Date; it lagged the real release (v1.227.0 shipped 2026-07-24 with VERSION_DATE=2026-07-20; v1.228.6 shipped 2026-08-08 with VERSION_DATE still 2026-07-28). This asserts VERSION_DATE equals the declared release-prep authority — the CHANGELOG '## [vVERSION] - DATE' heading for the version in the VERSION file — NOT the wall clock (that would break reproducibility and conflate release metadata with BuildDate). So a release-prep that bumps VERSION+CHANGELOG but forgets VERSION_DATE cannot merge. Static; reads VERSION, VERSION_DATE, CHANGELOG.md; no host."
# meta:input="VERSION, VERSION_DATE, CHANGELOG.md"
# meta:output="PASS/FAIL; exit 1 on incoherence"
# meta:depends="bash,grep,sed"
# meta:inventory.files="VERSION,VERSION_DATE,CHANGELOG.md"
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "=== check-version-date-coherence (v1.228.7) ==="

for f in VERSION VERSION_DATE CHANGELOG.md; do
    [[ -f "$f" ]] || { bad "MISSING: $f"; echo "=== version-date: FAILS=$FAILS ==="; exit 1; }
done

VERSION="$(tr -d '[:space:]' < VERSION)"
VDATE="$(tr -d '[:space:]' < VERSION_DATE)"

# VERSION_DATE must be strict ISO YYYY-MM-DD (the version.sh resolver rejects
# anything else to "unknown"; a guard that accepts junk would let that ship).
if [[ "$VDATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    ok "VERSION_DATE is strict ISO ($VDATE)"
else
    bad "VERSION_DATE not strict ISO YYYY-MM-DD: '$VDATE'"
fi

# The declared authority: the CHANGELOG heading for THIS version.
# Format: '## [v1.228.6] - 2026-08-08 — ...'
CL_DATE="$(grep -m1 -E "^## \[v${VERSION//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" CHANGELOG.md \
            | sed -E 's/^## \[v[^]]+\] - ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')"

if [[ -z "$CL_DATE" ]]; then
    bad "no CHANGELOG heading '## [v${VERSION}] - YYYY-MM-DD' — the release-prep authority for VERSION_DATE is absent"
elif [[ "$CL_DATE" == "$VDATE" ]]; then
    ok "VERSION_DATE ($VDATE) == CHANGELOG v${VERSION} heading date ($CL_DATE)"
else
    bad "VERSION_DATE ($VDATE) != CHANGELOG v${VERSION} heading date ($CL_DATE) — release-prep bumped VERSION/CHANGELOG but not VERSION_DATE"
fi

echo "=== version-date: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]]
