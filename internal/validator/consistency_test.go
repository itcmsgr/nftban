// =============================================================================
// NFTBan v1.82 - Consistency Axis Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="consistency_test"
// meta:type="test"
// meta:version="1.82.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Tests for v1.82 Step 3 consistency axis evaluation"
// meta:inventory.files="internal/validator/consistency_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import "testing"

func TestConsistency_AllEnabled_AllPresent(t *testing.T) {
	modules := ModuleHealthMap{
		BotGuard: &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
		DDoS:     &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
		Portscan: &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
		LoginMon: &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
	}
	cr := evaluateConsistency(modules)
	if cr.Overall != "ok" {
		t.Errorf("overall = %s, want ok (all enabled + present)", cr.Overall)
	}
	if len(cr.Findings) != 0 {
		t.Errorf("findings = %d, want 0", len(cr.Findings))
	}
}

func TestConsistency_EnabledButMissing(t *testing.T) {
	modules := ModuleHealthMap{
		BotGuard: &ModuleHealth{Config: ConfigEnabled, Structural: StructuralMissing},
		DDoS:     &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
	}
	cr := evaluateConsistency(modules)
	if cr.Overall != "mismatch" {
		t.Errorf("overall = %s, want mismatch (botguard enabled but missing)", cr.Overall)
	}
	if len(cr.Findings) != 1 {
		t.Fatalf("findings = %d, want 1", len(cr.Findings))
	}
	if cr.Findings[0].Code != CodeConsistencyMismatch {
		t.Errorf("finding code = %s, want %s", cr.Findings[0].Code, CodeConsistencyMismatch)
	}
}

func TestConsistency_DisabledPresent_ValidResidual(t *testing.T) {
	// Rule 8: disabled + present = valid residual, NOT mismatch
	modules := ModuleHealthMap{
		DDoS:     &ModuleHealth{Config: ConfigDisabled, Structural: StructuralPresent},
		Portscan: &ModuleHealth{Config: ConfigDisabled, Structural: StructuralPresent},
	}
	cr := evaluateConsistency(modules)
	if cr.Overall != "ok" {
		t.Errorf("overall = %s, want ok (disabled + present = valid residual)", cr.Overall)
	}
	if len(cr.Findings) != 0 {
		t.Errorf("findings = %d, want 0 (residual is not a mismatch)", len(cr.Findings))
	}
}

func TestConsistency_DisabledMissing_Expected(t *testing.T) {
	modules := ModuleHealthMap{
		BotGuard: &ModuleHealth{Config: ConfigDisabled},
	}
	cr := evaluateConsistency(modules)
	if cr.Overall != "ok" {
		t.Errorf("overall = %s, want ok (disabled + missing = expected)", cr.Overall)
	}
}

func TestConsistency_MultipleModules_OneMismatch(t *testing.T) {
	modules := ModuleHealthMap{
		BotGuard: &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
		DDoS:     &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
		Portscan: &ModuleHealth{Config: ConfigEnabled, Structural: StructuralMissing}, // mismatch
		LoginMon: &ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent},
	}
	cr := evaluateConsistency(modules)
	if cr.Overall != "mismatch" {
		t.Errorf("overall = %s, want mismatch (one module mismatched)", cr.Overall)
	}
	if len(cr.Findings) != 1 {
		t.Errorf("findings = %d, want 1", len(cr.Findings))
	}
}

func TestConsistency_NilModules(t *testing.T) {
	modules := ModuleHealthMap{}
	cr := evaluateConsistency(modules)
	if cr.Overall != "ok" {
		t.Errorf("overall = %s, want ok (no modules = no mismatches)", cr.Overall)
	}
}
