// SPDX-License-Identifier: MPL-2.0
// meta:name="whitelist_convergence_assertion_v1228_5_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.228.5: assertWhitelistConvergence must PASS on CONVERGED, FAIL on FAILED (never silently clean), FAIL on a DEFERRED that survived to validation, FAIL CLOSED on an unrecognized verdict, and PASS-as-UNKNOWN on the empty/legacy value without claiming convergence."
// meta:inventory.files="internal/installer/validate/whitelist_convergence_assertion_v1228_5_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package validate

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
)

// CONVERGED is the only value that may pass on the merits.
func TestAssertWhitelistConvergenceConvergedPasses(t *testing.T) {
	r := assertWhitelistConvergence(AssertionOpts{WhitelistConvergence: "CONVERGED"}, nolog())
	if !r.Passed {
		t.Fatalf("CONVERGED must PASS, got FAIL: %s", r.Detail)
	}
	if r.Name != "whitelist_convergence_ok" {
		t.Fatalf("assertion name changed: %q", r.Name)
	}
}

// FAILED must never be clean — this is the whole point of persisting the verdict.
// A passing result here would let a host whose whitelist.d layer is unprojected
// (management IPs unenforced) finish the install COMMITTED.
func TestAssertWhitelistConvergenceFailedFails(t *testing.T) {
	r := assertWhitelistConvergence(AssertionOpts{WhitelistConvergence: "FAILED"}, nolog())
	if r.Passed {
		t.Fatalf("FAILED must FAIL the assertion, got PASS: %s", r.Detail)
	}
	if r.Detail == "" {
		t.Fatal("a failing verdict must carry an actionable Detail (it becomes FAILURE_REASON)")
	}
}

// DEFERRED is valid only BEFORE the post-daemon convergence step. Reaching
// validation means convergence never produced a verdict, so it must not survive
// into a COMMITTED record.
func TestAssertWhitelistConvergenceDeferredDoesNotSurvive(t *testing.T) {
	r := assertWhitelistConvergence(AssertionOpts{WhitelistConvergence: "DEFERRED"}, nolog())
	if r.Passed {
		t.Fatalf("DEFERRED must not survive to a COMMITTED verdict, got PASS: %s", r.Detail)
	}
}

// BACKWARD COMPATIBILITY: an install_state written before v1.228.5 has no
// WHITELIST_CONVERGENCE= line, so the field parses to "". That must not become a
// false FAILED (every legacy host would go DEGRADED on its next revalidate) and
// must not be reported as CONVERGED either.
func TestAssertWhitelistConvergenceEmptyIsUnknownNotFailNotConverged(t *testing.T) {
	r := assertWhitelistConvergence(AssertionOpts{}, nolog())
	if !r.Passed {
		t.Fatalf("empty/legacy value must NOT fail a pre-v1.228.5 install: %s", r.Detail)
	}
	if !strings.Contains(r.Detail, "UNKNOWN") {
		t.Fatalf("empty value must be reported as UNKNOWN, got %q", r.Detail)
	}
	if strings.Contains(r.Detail, "CONVERGED") {
		t.Fatalf("empty value must NOT be reported as a convergence claim, got %q", r.Detail)
	}
}

// An unrecognized value is not evidence of success.
func TestAssertWhitelistConvergenceUnknownValueFailsClosed(t *testing.T) {
	r := assertWhitelistConvergence(AssertionOpts{WhitelistConvergence: "PROBABLY_FINE"}, nolog())
	if r.Passed {
		t.Fatalf("an unrecognized verdict must FAIL CLOSED, got PASS: %s", r.Detail)
	}
}

// REGISTRATION proof: the assertion must actually run inside the production entry
// point, not merely exist. A dead assertion is the same defect as a dead field.
// A FAILED verdict must also make AllPassed false — that is the link that turns
// the persisted verdict into installer DEGRADED (phases.go / revalidate.go).
func TestRunAssertionsWithOptsRunsWhitelistConvergence(t *testing.T) {
	mock := executor.NewMockExecutor()
	opts := AssertionOpts{
		PanelAdapters:        []panelfw.PanelAdapter{},
		WhitelistConvergence: "FAILED",
	}.WithPanelPolicy(panelfw.DefaultPolicy())

	results := RunAssertionsWithOpts(mock, 22, newTestLogger(), opts)

	var found bool
	for _, r := range results {
		if r.Name == "whitelist_convergence_ok" {
			found = true
			if r.Passed {
				t.Errorf("WHITELIST_CONVERGENCE=FAILED must produce a failing assertion")
			}
		}
	}
	if !found {
		t.Fatal("whitelist_convergence_ok is not registered in RunAssertionsWithOpts — the persisted verdict would be dead weight")
	}
	if AllPassed(results) {
		t.Fatal("AllPassed must be false when the whitelist convergence verdict is FAILED")
	}
}
