// =============================================================================
// NFTBan v1.120 - Schema-freeze regression guard for V120 Operator Temp Whitelist Guard
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="whitelist_schema_freeze_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-18"
// meta:description="V120 schema-freeze regression guard — asserts SchemaVersionCurrent stays 1.83.0 throughout the V120 Operator Temp Whitelist Guard implementation. Per V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md verdict SCHEMA_STAYS_FROZEN (conditional on --json deferral). Mirrors internal/blacklist/schema_freeze_test.go from v1.119."
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

package whitelist

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/validator"
)

// TestSchemaVersionUnchangedByV120OperatorSessionWhitelist is the v1.120
// equivalent of v1.119's TestSchemaVersionUnchangedByManualCIDRFix
// (located in internal/blacklist/schema_freeze_test.go). It asserts that
// the V120 Operator Temp Whitelist Guard implementation does NOT bump the
// frozen schema version. Per V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md
// verdict SCHEMA_STAYS_FROZEN (conditional on --json deferral), all seven
// surface analyses (Q1 text CLI, Q2 list --json [DEFERRED], Q3 file format
// EXPIRES_AT, Q4 status output, Q5 metrics, Q6 validator/schema, Q7 nftables
// kernel set) returned NO schema impact.
//
// If this test fails, the V120 implementation has accidentally introduced
// a schema-impacting change. Stop, re-read V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md,
// and either revert the change OR open a separate
// OPEN_V12x_SCHEMA_UNFREEZE_GATE for the new schema version BEFORE
// merging the implementation PR.
//
// Co-located in internal/whitelist/ because this package is the load-bearing
// site of the V120 EXPIRES_AT loader extension; placing the guard adjacent
// to the typed-loader changes makes drift-detection blast radius local
// (mirrors v1.119's adjacency at internal/blacklist/schema_freeze_test.go).
func TestSchemaVersionUnchangedByV120OperatorSessionWhitelist(t *testing.T) {
	const expectedSchema = "1.84.0"
	if validator.SchemaVersionCurrent != expectedSchema {
		t.Fatalf("SchemaVersionCurrent = %q, want %q — V120 Operator Temp Whitelist Guard MUST NOT "+
			"bump schema (per V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md verdict "+
			"SCHEMA_STAYS_FROZEN). If a schema bump is genuinely needed (e.g. for --json "+
			"support on the new whitelist-session subcommand), request "+
			"OPEN_V12x_SCHEMA_UNFREEZE_GATE separately.",
			validator.SchemaVersionCurrent, expectedSchema)
	}
}
