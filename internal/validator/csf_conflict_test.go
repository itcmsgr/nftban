// =============================================================================
// NFTBan — CSF-CLOSE-5 gate: PROTECTED may not be asserted on a contested host
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator-csf-conflict-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-11"
// meta:description="Locks CSF-CLOSE-5: a CSF-PRESENT or CSF-UNKNOWN verdict produces an error-severity finding so the validator cannot return PROTECTED, while a genuinely neutralized host (masked units, .disabled payload) still reaches PROTECTED."
// meta:inventory.files="internal/validator/csf_conflict.go,internal/validator/validator.go"
// meta:inventory.privileges="none"
// =============================================================================
//
// The two shapes this must never regress on (el9-clean, 2026-08-11):
//
//	  ARM 3  csf.service failed BUT ENABLED, binary executable, config absent.
//	         Every "is it active" probe said no; CSF came back with 129 rules.
//	  ARM 4  CSF listed in CONFLICTS, disarm skipped, lfd enabled, binary
//	         executable. status=PROTECTED.
//
//		SERVICE INACTIVE != AUTHORITY ABSENT
//		UNKNOWN          != PROTECTED-by-assumption
package validator

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// readSourceStripped returns a source file with // comments removed, so a
// static assertion cannot be satisfied or violated by prose describing the
// defect it guards against.
func readSourceStripped(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return regexp.MustCompile(`(?m)//.*$`).ReplaceAllString(string(b), "")
}

func hasErrorFinding(f *Finding) bool {
	return f != nil && f.Severity == SeverityError && f.Code == CodeCSFConflict
}

// ---------------------------------------------------------------------------
// PRESENT => must produce an error finding (cannot be PROTECTED)
// ---------------------------------------------------------------------------

func TestClose5_Present_ProducesErrorFinding(t *testing.T) {
	r := CSFConflictResult{
		State:    CSFPresent,
		Evidence: []string{"csf.service enabled (failed) — re-enters on boot"},
	}
	f := csfConflictFinding(r)
	if !hasErrorFinding(f) {
		t.Fatalf("CSF PRESENT must yield an error-severity %s finding, got %+v", CodeCSFConflict, f)
	}
	if !strings.Contains(f.Message, "re-enter") && !strings.Contains(f.Message, "sole firewall authority") {
		t.Errorf("finding message must state the authority problem, got %q", f.Message)
	}
	if f.Remediation == "" {
		t.Error("a contested-host finding must tell the operator what to do")
	}
}

// UNKNOWN must fail closed — this is the invariant that stops an unqueryable
// host from silently passing as clean.
func TestClose5_Unknown_FailsClosed(t *testing.T) {
	f := csfConflictFinding(CSFConflictResult{
		State:    CSFUnknown,
		Evidence: []string{"systemd not queryable"},
	})
	if !hasErrorFinding(f) {
		t.Fatalf("CSF UNKNOWN must fail closed with an error finding, got %+v", f)
	}
	if !strings.Contains(strings.ToUpper(f.Message), "UNKNOWN") {
		t.Errorf("UNKNOWN finding must say so plainly, got %q", f.Message)
	}
}

// NOT_OBSERVED must stay silent, or every clean host would be degraded.
func TestClose5_NotObserved_ProducesNoFinding(t *testing.T) {
	if f := csfConflictFinding(CSFConflictResult{State: CSFNotObserved}); f != nil {
		t.Errorf("a clean host must produce no CSF finding, got %+v", f)
	}
}

// ---------------------------------------------------------------------------
// The finding must actually change the verdict — not merely exist
// ---------------------------------------------------------------------------

func TestClose5_ErrorFindingPreventsProtected(t *testing.T) {
	// Baseline: no findings, all families protected. NOTE this evaluates to
	// StatusIdle here because the fixture declares no modules — and the shell
	// status surface maps BOTH `protected` and `idle` to the operator-visible
	// word PROTECTED (cmd_status.sh: `protected)` and `idle)` both echo
	// "PROTECTED"). So the invariant under test is "not either of them",
	// not merely "not StatusProtected".
	clean := &ValidationResult{
		Status:   StatusProtected,
		Families: []FamilyResult{{Status: StatusProtected}},
	}
	base := evaluateOverallStatus(clean)
	if base != StatusProtected && base != StatusIdle {
		t.Fatalf("baseline must read as protected-or-idle, got %s — arm below would prove nothing", base)
	}

	// Same host, plus the CSF conflict finding.
	contested := &ValidationResult{
		Status:   StatusProtected,
		Families: []FamilyResult{{Status: StatusProtected}},
	}
	f := csfConflictFinding(CSFConflictResult{
		State:    CSFPresent,
		Evidence: []string{"lfd.service enabled (inactive) — re-enters on boot"},
	})
	contested.Findings = append(contested.Findings, *f)

	got := evaluateOverallStatus(contested)
	if got == StatusProtected || got == StatusIdle {
		t.Errorf("host with re-enterable CSF still reads as PROTECTED to the operator (%s) — "+
			"the lying-status defect (arms 3/4)", got)
	}
	if got != StatusDegraded {
		t.Errorf("contested host should be DEGRADED (NFTBan itself is healthy), got %s", got)
	}
}

// ---------------------------------------------------------------------------
// Neutralized host must still reach PROTECTED, or takeover could never succeed
// ---------------------------------------------------------------------------

func TestClose5_MaskedUnitsAndDisabledPayload_AreNotAConflict(t *testing.T) {
	// A successful takeover leaves: units MASKED, payload renamed .disabled.
	// If that read as a conflict, no host could ever be PROTECTED after
	// takeover — the fix would have replaced a false PASS with a false FAIL.
	if f := csfConflictFinding(CSFConflictResult{State: CSFNotObserved}); f != nil {
		t.Fatalf("post-takeover shape must not be reported as a conflict, got %+v", f)
	}

	// And the enabled-state classifier must treat `masked` as neutralized.
	for _, st := range []string{"masked", "masked-runtime", "disabled"} {
		if isReentryEnabledState(st) {
			t.Errorf("%q must NOT count as re-entry — it is what neutralization produces", st)
		}
	}
	// ...while the states that really do re-enter must be caught.
	for _, st := range []string{"enabled", "enabled-runtime", "static", "alias"} {
		if !isReentryEnabledState(st) {
			t.Errorf("%q re-enters on boot and must be caught (arm-3 shape)", st)
		}
	}
}

// ---------------------------------------------------------------------------
// WIRING — the probe must actually reach the verdict, not be dead code
// ---------------------------------------------------------------------------

// Without this, every other arm in this file still passes if the call site in
// ValidateKernel is deleted: the probe becomes unreachable and status lies
// again, silently. A falsifiability control found exactly that hole.
//
// ValidateKernel needs a live nft/systemd host, so this cannot be exercised
// behaviourally in a hermetic test. A static assertion on the shipped call
// site is the honest substitute — weaker than behavioural proof, and stated
// as such rather than dressed up.
func TestClose5_FindingIsWiredIntoValidateKernel(t *testing.T) {
	src := readSourceStripped(t, "validator.go")
	if !strings.Contains(src, "csfConflictFinding(DetectCSFConflict())") {
		t.Error("ValidateKernel no longer calls csfConflictFinding(DetectCSFConflict()) — " +
			"the CSF conflict probe is dead code and PROTECTED can lie again")
	}
	if !strings.Contains(src, "result.Findings = append(result.Findings, *f)") {
		t.Error("the CSF finding is computed but never appended to result.Findings")
	}
}

// ---------------------------------------------------------------------------
// Purity — this probe must never mutate or execute a vendor binary
// ---------------------------------------------------------------------------

func TestClose5_ProbeNeverExecutesVendorBinary(t *testing.T) {
	// Static guard on the shipped source: `csf -s` as a probe re-armed a
	// competing firewall from a read-only report (v1.229.0 R0). Comments are
	// stripped so prose describing that defect can neither satisfy nor
	// violate the assertion (GUARD_SUBJECT == GUARD_INPUT).
	src := readSourceStripped(t, "csf_conflict.go")
	for _, forbidden := range []string{
		`Command("/usr/sbin/csf"`, `Command("csf"`, `Command("/usr/sbin/lfd"`, `Command("lfd"`,
		`"-s"`, `"--start"`, `os.Remove`, `os.Rename`, `WriteFile`,
	} {
		if strings.Contains(src, forbidden) {
			t.Errorf("read-only CSF probe contains %q — observation must not mutate or execute vendor binaries", forbidden)
		}
	}
}
