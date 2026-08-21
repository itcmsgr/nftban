package validator

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// v1.229.7 PR-3A — StructuralUnknown propagation contract.
//
// These are negative controls at the SEMANTIC BOUNDARY, not unit tests of an
// enum. The defect they exist for is not "the constant is missing"; it is that
// an unknown structural axis silently became a top-level PROTECTED verdict.
//
//	UNKNOWN AT AN AUTHORITATIVE AXIS
//	  -> UNKNOWN AT CONSISTENCY RESULT
//	  -> UNKNOWN MUST REACH OVERALL
//	  -> TOP-LEVEL STATUS MUST NOT CLAIM PROTECTED
//
// and, in the other direction:
//
//	UNKNOWN != PASS · != CONFIRMED DRIFT · != UNPROTECTED

func consistencyFor(h *ModuleHealth) (*ConsistencyResult, ConsistencyCheck) {
	cr := &ConsistencyResult{Overall: "ok"}
	checkModuleConsistency(cr, "ddos", h)
	if len(cr.Checks) == 0 {
		return cr, ConsistencyCheck{}
	}
	return cr, cr.Checks[0]
}

// U-N1: StructuralUnknown entering consistency MUST NOT leave Overall == "ok".
func TestUN1_UnknownMustNotLeaveOverallOK(t *testing.T) {
	cr, chk := consistencyFor(&ModuleHealth{
		Config: ConfigEnabled, Structural: StructuralUnknown,
		StructuralReason: ReasonExpectationUnknown,
	})
	if cr.Overall == "ok" {
		t.Fatalf("U-N1 FAILED: StructuralUnknown left ConsistencyOverall=ok — unknown collapsed to pass")
	}
	if chk.Result == "ok" {
		t.Fatalf("U-N1 FAILED: check result=ok for an unknown structural axis")
	}
	if len(cr.Findings) == 0 {
		t.Fatalf("U-N1 FAILED: no finding emitted — unknown would never reach the top-level status")
	}
	if cr.Findings[0].Code != CodeConsistencyUnknown {
		t.Fatalf("U-N1 FAILED: expected the EXPECTATION-side code %s, got %s",
			CodeConsistencyUnknown, cr.Findings[0].Code)
	}
}

// U-N2: an unknown consistency result MUST NOT yield a PROTECTED final status.
// Asserted through the REAL status evaluator, not a re-implementation of it.
func TestUN2_UnknownMustNotBecomeProtected(t *testing.T) {
	cr, _ := consistencyFor(&ModuleHealth{
		Config: ConfigEnabled, Structural: StructuralUnknown,
		StructuralReason: ReasonExpectationUnknown,
	})
	res := &ValidationResult{
		Status:             StatusProtected, // the false-green we must not keep
		ConsistencyOverall: cr.Overall,
		Findings:           cr.Findings,
	}
	if got := evaluateOverallStatus(res); got == StatusProtected {
		t.Fatalf("U-N2 FAILED: ConsistencyOverall=%q still produced top-level PROTECTED", cr.Overall)
	}
}

// U-N3: an unrecognised StructuralState MUST NOT fall through to OK.
// This is the future-proofing control: it simulates someone extending the enum
// without teaching this consumer.
func TestUN3_InvalidStateMustNotFallThroughToOK(t *testing.T) {
	cr, chk := consistencyFor(&ModuleHealth{
		Config: ConfigEnabled, Structural: StructuralState("partially-there"),
	})
	if chk.Result == "ok" || cr.Overall == "ok" {
		t.Fatalf("U-N3 FAILED: unrecognised StructuralState became a pass (result=%q overall=%q)",
			chk.Result, cr.Overall)
	}
	if len(cr.Findings) == 0 || cr.Findings[0].Code != CodeConsistencyInvalidState {
		t.Fatalf("U-N3 FAILED: unrecognised state did not raise %s", CodeConsistencyInvalidState)
	}
}

// U-N4: PRESENT where MISSING was expected must be diagnosed as unexpected
// live objects — NOT as "missing". Sending an operator to `enable` when the
// actual condition is a live stale pipeline is the wrong remedy.
func TestUN4_DriftDiagnosticMustNotSayMissing(t *testing.T) {
	cr, chk := consistencyFor(&ModuleHealth{
		Config: ConfigEnabled, Structural: StructuralMissing,
		StructuralReason: ReasonDriftPresent,
	})
	blob := strings.ToLower(chk.Detail + " " + cr.Findings[0].Message)
	if strings.Contains(blob, "missing") || strings.Contains(blob, "absent") {
		t.Fatalf("U-N4 FAILED: drift diagnostic claims absence: %q", blob)
	}
	if !strings.Contains(blob, "present") {
		t.Fatalf("U-N4 FAILED: drift diagnostic never says the objects are PRESENT: %q", blob)
	}
	if chk.Result != "mismatch" {
		t.Fatalf("U-N4 FAILED: drift must still FAIL, got %q", chk.Result)
	}
}

// U-P1/U-P2: the correction must not make unknown contagious. The two valid
// states still pass exactly as before. A guard that fails everything proves
// nothing.
func TestUP_ValidStatesStillPass(t *testing.T) {
	if cr, chk := consistencyFor(&ModuleHealth{Config: ConfigEnabled, Structural: StructuralPresent}); chk.Result != "ok" || cr.Overall != "ok" {
		t.Fatalf("U-P1 FAILED: enabled+present no longer passes (result=%q overall=%q)", chk.Result, cr.Overall)
	}
	if cr, chk := consistencyFor(&ModuleHealth{Config: ConfigDisabled, Structural: StructuralMissing}); chk.Result != "ok" || cr.Overall != "ok" {
		t.Fatalf("U-P2 FAILED: disabled+missing no longer passes (result=%q overall=%q)", chk.Result, cr.Overall)
	}
	// And a real mismatch must still be a mismatch, not an unknown.
	if cr, _ := consistencyFor(&ModuleHealth{Config: ConfigEnabled, Structural: StructuralMissing}); cr.Overall != "mismatch" {
		t.Fatalf("U-P3 FAILED: genuine absence no longer reports mismatch (overall=%q)", cr.Overall)
	}
}

// -----------------------------------------------------------------------------
// V1 / V2 / V3 — the plan-record consumer contract for MODE=auto.
// -----------------------------------------------------------------------------

func withPlan(t *testing.T, cfgMode, planModule, planConfigured, planEffective string) func() {
	t.Helper()
	cfg, run := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(cfg, "conf.d", "ddos"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "DDOS_ENABLED=true\nDDOS_MODE=" + cfgMode + "\n"
	if err := os.WriteFile(filepath.Join(cfg, "conf.d", "ddos", "main.conf"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if planEffective != "ABSENT" {
		rec := "NFTBAN_PLAN_MODULE=" + planModule + "\n" +
			"NFTBAN_PLAN_CONFIGURED_MODE=" + planConfigured + "\n" +
			"NFTBAN_PLAN_EFFECTIVE_MODE=" + planEffective + "\n"
		if err := os.WriteFile(filepath.Join(run, "module-plan-ddos.env"), []byte(rec), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	oc, or := ConfigDir, RunDir
	ConfigDir, RunDir = cfg, run
	return func() { ConfigDir, RunDir = oc, or }
}

func effMode(t *testing.T) string {
	t.Helper()
	return readEffectiveMode("ddos", "conf.d/ddos/main.conf.local", "conf.d/ddos/main.conf", "DDOS_MODE")
}

// V1: configured=auto + plan=suricata -> the SURICATA contract is derived.
func TestV1_AutoPlanSuricata(t *testing.T) {
	defer withPlan(t, "auto", "ddos", "auto", "suricata")()
	if got := effMode(t); got != "suricata" {
		t.Fatalf("V1 FAILED: want suricata, got %q", got)
	}
}

// V2: configured=auto + plan=classic -> the CLASSIC contract is derived.
func TestV2_AutoPlanClassic(t *testing.T) {
	defer withPlan(t, "auto", "ddos", "auto", "classic")()
	if got := effMode(t); got != "classic" {
		t.Fatalf("V2 FAILED: want classic, got %q", got)
	}
}

// V3: configured=auto + missing/invalid plan -> UNKNOWN. Never infer a mode.
//
//	MISSING PLAN != CLASSIC · != SURICATA · != DISABLED
//
// Each row is a distinct way the record can be unusable. A present-but-broken
// record is a BROKEN CONTRACT, not evidence of absence, so none of them may
// degrade into "well, the operator said auto".
func TestV3_AutoPlanUnusableIsUnknown(t *testing.T) {
	for _, tc := range []struct{ name, mod, cfgd, eff string }{
		{"missing record", "ddos", "auto", "ABSENT"},
		{"wrong module", "portscan", "auto", "classic"},
		{"empty effective_mode", "ddos", "auto", ""},
		{"garbage effective_mode", "ddos", "auto", "classicish"},
		{"legacy hybrid passthrough", "ddos", "auto", "unknown"},
		{"stale: resolved from a different configured_mode", "ddos", "classic", "classic"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			defer withPlan(t, "auto", tc.mod, tc.cfgd, tc.eff)()
			if got := effMode(t); got != modeUnknown {
				t.Fatalf("V3 FAILED (%s): inferred %q instead of refusing to guess", tc.name, got)
			}
			h := evaluateDDoS(&RulesetDocument{})
			if h.Structural != StructuralUnknown {
				t.Fatalf("V3 FAILED (%s): structural=%q, want unknown", tc.name, h.Structural)
			}
			cr, _ := consistencyFor(h)
			if cr.Overall == "ok" {
				t.Fatalf("V3 FAILED (%s): unusable plan still produced overall=ok", tc.name)
			}
		})
	}
}

// V4: an explicit operator mode is self-authoritative — no plan needed — and a
// plan may RESOLVE `auto` but must never OVERRIDE an explicit intent.
func TestV4_ExplicitModeAuthority(t *testing.T) {
	defer withPlan(t, "suricata", "ddos", "suricata", "ABSENT")()
	if got := effMode(t); got != "suricata" {
		t.Fatalf("V4 FAILED: explicit suricata with no plan should stand, got %q", got)
	}
	restore := withPlan(t, "classic", "ddos", "classic", "suricata")
	defer restore()
	if got := effMode(t); got != modeUnknown {
		t.Fatalf("V4 FAILED: plan contradicting explicit config must be UNKNOWN, got %q", got)
	}
}

// U-P4: an unknown STRUCTURAL axis must not suppress the EFFECTIVE axis.
// Regression control: the first cut of this change returned early on unknown,
// which threw away enforcement counters that had actually been observed. A
// counter reading is a fact about the kernel; it does not depend on knowing
// which mode was planned.
//
//	UNKNOWN MUST NOT BE CONTAGIOUS ACROSS AXES
func TestUP4_UnknownStructuralDoesNotSuppressEffective(t *testing.T) {
	defer withPlan(t, "auto", "ddos", "auto", "ABSENT")()
	doc := ParseRuleset(&NftRuleset{Nftables: []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_sanity"}},
		{Counter: &NftCounter{Family: "ip", Table: "nftban", Name: "input_ct_ssh_drop", Packets: 42}},
	}})
	h := evaluateDDoS(doc)
	if h.Structural != StructuralUnknown {
		t.Fatalf("U-P4 setup wrong: structural=%q, want unknown", h.Structural)
	}
	if h.Effective != EffectiveEnforcing {
		t.Fatalf("U-P4 FAILED: an observed enforcing counter was discarded because the structural expectation was unknown (effective=%q)", h.Effective)
	}
}
