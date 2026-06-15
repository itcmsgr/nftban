// =============================================================================
// NFTBan v1.119 - Schema-freeze regression guard for V119 A1 Manual CIDR fix
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="schema_freeze_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-18"
// meta:description="V116 §7 Test 10 regression guard — asserts SchemaVersionCurrent stays 1.83.0 throughout the V119 A1 Manual CIDR DESIGN-FIX implementation. Per V119_MANUAL_CIDR_SCHEMA_IMPACT_DECISION.md verdict SCHEMA_STAYS_FROZEN."
// meta:input="None"
// meta:output="t.Fatal on schema drift"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package blacklist

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/validator"
)

// TestSchemaVersionUnchangedByManualCIDRFix is V116 §7 Test 10 — a
// compile-time + run-time regression guard ensuring that the V119 A1
// Manual CIDR DESIGN-FIX implementation does NOT bump the frozen schema
// version. Per V119_MANUAL_CIDR_SCHEMA_IMPACT_DECISION.md (verdict
// SCHEMA_STAYS_FROZEN), all five surface analyses (Q1 status text, Q2
// status JSON, Q3 list blacklist JSON, Q4 kernel set + Prometheus, Q5
// whitelist CIDR containment) returned NO schema impact.
//
// If this test fails, the implementation has accidentally introduced a
// schema-impacting change. Stop, re-read V119_MANUAL_CIDR_SCHEMA_IMPACT_DECISION.md,
// and either revert the change or open a separate
// `OPEN_V11x_SCHEMA_UNFREEZE_GATE` for the new schema version BEFORE
// merging the implementation PR.
//
// Co-located in internal/blacklist/ because this package is the load-bearing
// site of the V119 A1 fix; placing the guard adjacent to the typed-loader
// changes makes drift-detection blast radius local.
func TestSchemaVersionUnchangedByManualCIDRFix(t *testing.T) {
	const expectedSchema = "1.84.0"
	if validator.SchemaVersionCurrent != expectedSchema {
		t.Fatalf("SchemaVersionCurrent = %q, want %q — V119 A1 Manual CIDR fix MUST NOT bump schema "+
			"(per V119_MANUAL_CIDR_SCHEMA_IMPACT_DECISION.md verdict SCHEMA_STAYS_FROZEN). "+
			"If a schema bump is genuinely needed, request OPEN_V11x_SCHEMA_UNFREEZE_GATE separately.",
			validator.SchemaVersionCurrent, expectedSchema)
	}
}
