#!/usr/bin/env bash
# =============================================================================
# NFTBan - VERSION_DATE coherence guard falsifiability (v1.228.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="version_date_coherence_v1228_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="Proves check-version-date-coherence.sh discriminates: on the real tree it PASSES; against a fixture where VERSION_DATE disagrees with the CHANGELOG heading it FAILS; against a fixture with no CHANGELOG heading for the version it FAILS; against a non-ISO VERSION_DATE it FAILS; and against a coherent fixture it PASSES. The guard compares to the DECLARED release-prep authority (CHANGELOG heading), never the wall clock. Static, hermetic."
# meta:ta.id="version_date_coherence_v1228_7_test"
# meta:ta.owner="packaging"
# meta:ta.module="version-date-coherence"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GUARD="$ROOT/scripts/ci/check-version-date-coherence.sh"
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# The guard cd's to its own repo root, so exercise it against fixtures by
# building a throwaway tree with a copy of the guard.
run_fixture(){ # <version> <version_date> <changelog-heading-or-EMPTY>  -> rc
    local d; d="$(mktemp -d)"
    mkdir -p "$d/scripts/ci"
    cp "$GUARD" "$d/scripts/ci/check-version-date-coherence.sh"
    printf '%s\n' "$1" > "$d/VERSION"
    printf '%s\n' "$2" > "$d/VERSION_DATE"
    if [[ -n "$3" ]]; then printf '%s\n' "$3" > "$d/CHANGELOG.md"; else printf 'no headings here\n' > "$d/CHANGELOG.md"; fi
    ( cd "$d" && bash scripts/ci/check-version-date-coherence.sh >/dev/null 2>&1 ); local rc=$?
    rm -rf "$d"; return $rc
}

echo "=== (0) real tree PASSES ==="
bash "$GUARD" >/dev/null 2>&1 && ok "real tree coherent" || no "real tree INCOHERENT — fix VERSION_DATE"

echo "=== (1) coherent fixture PASSES ==="
run_fixture "1.228.7" "2026-08-08" "## [v1.228.7] - 2026-08-08 — x" && ok "coherent fixture" || no "coherent fixture rejected"

echo "=== (2) stale VERSION_DATE FAILS (the exact defect) ==="
run_fixture "1.228.7" "2026-07-28" "## [v1.228.7] - 2026-08-08 — x" && no "stale date accepted" || ok "stale VERSION_DATE rejected"

echo "=== (3) missing CHANGELOG heading FAILS ==="
run_fixture "1.228.7" "2026-08-08" "## [v1.228.6] - 2026-08-08 — x" && no "missing heading accepted" || ok "missing heading rejected"

echo "=== (4) non-ISO VERSION_DATE FAILS ==="
run_fixture "1.228.7" "Aug 8 2026" "## [v1.228.7] - 2026-08-08 — x" && no "non-ISO accepted" || ok "non-ISO rejected"

echo "=== version_date_coherence_v1228_7: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
