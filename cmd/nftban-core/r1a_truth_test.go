// SPDX-License-Identifier: MPL-2.0
// meta:name="r1a_truth_test.go"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.224.0 Lane B (R2): assembleReport honors ParseMemBytes validity (RESOURCES-PARSEMEMBYTES-OK-DISCARDED). An unparseable live MemoryHigh/MemoryMax must fail into the explicit live-invalid/unavailable family with a tier-aware exit via the shared predicate — never a fabricated effMax=0 sized verdict. Began RED against v1.223.0; green as of R2 and wired into ordinary CI (build tag removed)."
// meta:inventory.files="cmd/nftban-core/r1a_truth_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// meta:execution_class="CI_UNIT"
package main

import (
	"strings"
	"testing"
)

// RESOURCES-PARSEMEMBYTES-OK-DISCARDED: a parse FAILURE on the effective MemoryHigh/
// MemoryMax must produce explicit invalid/unavailable evidence and a tier-aware exit —
// never a fabricated effMax=0 sized (FALLBACK_UNDERSIZED) verdict, and never accepted.
func TestAssembleReportParseFailureNotFabricatedZero(t *testing.T) {
	medium := calcFor(6 << 30)
	rep := assembleReport(medium, nil, false, props("garbage", "garbage", "64", ""), nil, false)

	if rep.Service.ProtectionActive {
		t.Errorf("ProtectionActive=true on unparseable effective limits; must never accept fabricated evidence")
	}
	st := rep.Service.State
	if st == "FALLBACK_UNDERSIZED" || st == "FALLBACK_MATCH" || st == "ACTIVE_MATCH" {
		t.Errorf("state=%s on unparseable MemoryMax; a parse failure must be explicit invalid/unavailable, not a sized verdict", st)
	}
	if !(strings.Contains(st, "UNAVAILABLE") || strings.Contains(st, "INVALID")) {
		t.Errorf("state=%s does not mark the effective read as invalid/unavailable; ParseMemBytes ok was discarded", st)
	}
	if rep.Service.Effective.Available {
		t.Errorf("Effective.Available=true on unparseable input; must be false")
	}
	// Required-protection tier (medium) with unverifiable live values → fail-closed exit 2,
	// same tier-aware stance as a failed systemctl show (shared predicate, no private path).
	if got := resourcesExitCode(rep); got != 2 {
		t.Errorf("medium parse-failure exit=%d want 2 (required-protection fail-closed)", got)
	}
	// small tier: incomplete evidence, not required → exit 1 (tier-aware, not a hard fail).
	small := assembleReport(calcFor(2<<30), nil, false, props("garbage", "garbage", "64", ""), nil, false)
	if got := resourcesExitCode(small); got != 1 {
		t.Errorf("small parse-failure exit=%d want 1 (incomplete evidence)", got)
	}
}
