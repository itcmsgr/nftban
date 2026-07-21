// SPDX-License-Identifier: MPL-2.0
//go:build r1a_red

// meta:name="r1a_red_test.go"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.224.0 Lane A1 (TEST-DEBT-V1_222_1-HEALTHRESOURCE-UNITS): INTENTIONALLY-RED report-assembly test for RESOURCES-PARSEMEMBYTES-OK-DISCARDED. assembleReport discards ParseMemBytes' ok, so an unparseable MemoryMax silently becomes effMax=0 and is classified as a sized FALLBACK_UNDERSIZED verdict rather than an explicit invalid/unavailable state. Governed by the r1a_red build tag (baseline suite stays green). NO product code changed."
// meta:inventory.files="cmd/nftban-core/r1a_red_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// meta:execution_class="MANUAL_FORENSIC"
// meta:red_lane="r1a_red — expected-failing against v1.223.0; flips green under Lane B"
package main

import (
	"strings"
	"testing"
)

// RESOURCES-PARSEMEMBYTES-OK-DISCARDED: a parse FAILURE on the effective MemoryMax must
// produce explicit invalid/unavailable evidence — never a fabricated effMax=0 that reads
// as a legitimate sized (FALLBACK_UNDERSIZED) verdict. ProtectionActive must stay false in
// either case (that direction is already safe), but the STATE must not launder a parse
// failure into a normal sizing outcome. v1.223.0: effMax=0 → FALLBACK_UNDERSIZED → RED.
func TestR1aAssembleReportParseFailureNotFabricatedZero(t *testing.T) {
	calc := calcFor(6 << 30) // medium
	rep := assembleReport(calc, nil, false, props("garbage", "garbage", "64", ""), nil, false)

	// Must NEVER be accepted as protected off unparseable input.
	if rep.Service.ProtectionActive {
		t.Errorf("ProtectionActive=true on unparseable effective limits; must never accept fabricated evidence")
	}
	// The state must signal invalid/unavailable evidence, NOT a fabricated sized verdict.
	st := rep.Service.State
	if st == "FALLBACK_UNDERSIZED" || st == "FALLBACK_MATCH" || st == "ACTIVE_MATCH" {
		t.Errorf("state=%s on unparseable MemoryMax; a parse failure must yield explicit invalid/unavailable evidence, not a sized verdict", st)
	}
	if !(strings.Contains(st, "UNAVAILABLE") || strings.Contains(st, "INVALID")) {
		t.Errorf("state=%s does not mark the effective read as invalid/unavailable; ParseMemBytes ok was discarded", st)
	}
}
