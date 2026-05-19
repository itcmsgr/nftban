// =============================================================================
// NFTBan v1.121 - Schema-freeze regression guard for V121 operator-safety hardening
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="render_schema_freeze_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-19"
// meta:description="V121 schema-freeze regression guard — asserts SchemaVersionCurrent stays 1.83.0 throughout the V121 operator-safety hardening implementation (Part A render-path SSH-port injection + verifier dual-surface check + Part B update github [VERSION] doc + CLI normalization). Mirrors V120's TestSchemaVersionUnchangedByV120OperatorSessionWhitelist pattern (internal/whitelist/schema_freeze_test.go) and V119's TestSchemaVersionUnchangedByManualCIDRFix (internal/blacklist/schema_freeze_test.go). Per V121_OPERATOR_SAFETY_HARDENING_SCHEMA_IMPACT_DECISION.md §5 mandate."
// meta:input="None"
// meta:output="t.Fatalf on schema drift"
// meta:depends="testing,internal/validator"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package render

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/validator"
)

// TestSchemaVersionUnchangedByV121OperatorSafetyHardening is the V121
// equivalent of v1.119's TestSchemaVersionUnchangedByManualCIDRFix and
// v1.120's TestSchemaVersionUnchangedByV120OperatorSessionWhitelist. It
// asserts that the V121 operator-safety hardening bundle (Part A:
// render-path SSH-port injection in this package + verifier dual-surface
// check in cli/lib/nftban/cli/cmd_update.sh; Part B: update version
// normalization in cli/lib/nftban/cli/cmd_update_methods.sh + registry
// docs in commands.registry.yml) does NOT bump the frozen schema version.
//
// Per V121_OPERATOR_SAFETY_HARDENING_SCHEMA_IMPACT_DECISION.md verdict
// SCHEMA_STAYS_FROZEN (unconditional), all seven surface analyses (render
// injection, verifier dual-surface, version stripping, registry docs,
// shell tests Part A + B, this guard) returned NO schema impact.
//
// If this test fails, the V121 implementation has accidentally introduced
// a schema-impacting change. Stop, re-read V121_OPERATOR_SAFETY_HARDENING_
// SCHEMA_IMPACT_DECISION.md, and either revert the change OR open a
// separate OPEN_V12x_SCHEMA_UNFREEZE_GATE for the new schema version
// BEFORE merging the implementation PR.
//
// Co-located in internal/installer/render/ because Part A's primary
// code-affecting change is in this package; placing the guard adjacent to
// the render-path injection makes drift-detection blast radius local
// (mirrors v1.119's adjacency at internal/blacklist/schema_freeze_test.go
// and v1.120's adjacency at internal/whitelist/schema_freeze_test.go).
func TestSchemaVersionUnchangedByV121OperatorSafetyHardening(t *testing.T) {
	const expectedSchema = "1.83.0"
	if validator.SchemaVersionCurrent != expectedSchema {
		t.Fatalf("SchemaVersionCurrent = %q, want %q — V121 operator-safety hardening "+
			"MUST NOT bump schema (per V121_OPERATOR_SAFETY_HARDENING_SCHEMA_IMPACT_DECISION.md "+
			"verdict SCHEMA_STAYS_FROZEN). If a schema bump is genuinely needed "+
			"(e.g., for a new metric surfacing the dual-surface verifier outcome "+
			"or for new registry-document-format fields), request "+
			"OPEN_V12x_SCHEMA_UNFREEZE_GATE separately.",
			validator.SchemaVersionCurrent, expectedSchema)
	}
}
