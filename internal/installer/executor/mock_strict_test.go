// SPDX-License-Identifier: MPL-2.0

package executor

import (
	"strings"
	"testing"
)

// v1.228.5 — controls for the mock's unregistered-command policy.
//
// The defect class these exist to prevent: MockExecutor keys results by the
// COLON-JOINED argv, and an unmatched key historically returned
// Result{ExitCode: 0}. A missing or stale fixture therefore became a SUCCESSFUL
// command execution, which is the worst possible failure mode for a negative test
// — it converts "I have no fixture for this" into "the command succeeded".
//
// MEASURED instance: switchop.Rebuild gained a --install-context argument, every
// argv-derived key in rebuild_test.go went stale, and three tests asserting exit 1
// and exit 2 silently received exit 0.

// TestMock_UnregisteredPermissiveByDefault pins the BACKWARD-COMPATIBLE default.
// This is the load-bearing control for the opt-in design: the large majority of
// existing tests construct a mock without registering every command they touch and
// legitimately rely on exit 0. If this test ever fails, the default flipped and
// those tests are about to break for reasons unrelated to their own subject.
func TestMock_UnregisteredPermissiveByDefault(t *testing.T) {
	m := NewMockExecutor()
	got := m.Run("/usr/sbin/nftban", "firewall", "rebuild")
	if got.ExitCode != 0 {
		t.Fatalf("default must stay permissive: got exit %d, want 0", got.ExitCode)
	}
}

// TestMock_StrictUnregisteredFailsLoudly proves the opt-in guard refuses to report
// success, and that the reason is discoverable from the Result alone.
func TestMock_StrictUnregisteredFailsLoudly(t *testing.T) {
	m := NewMockExecutor()
	m.StrictUnregistered = true

	got := m.Run("/usr/sbin/nftban", "firewall", "rebuild", "--install-context")
	if got.ExitCode != 255 {
		t.Fatalf("strict mode must fail loudly: got exit %d, want 255", got.ExitCode)
	}
	if !strings.Contains(got.Stderr, "UNREGISTERED command key") {
		t.Fatalf("stderr must name the failure class, got %q", got.Stderr)
	}
	// The key itself must be present, otherwise the operator/test author cannot
	// tell WHICH fixture is missing — an undiagnosable failure is barely better
	// than a silent one.
	if !strings.Contains(got.Stderr, "/usr/sbin/nftban:firewall:rebuild:--install-context") {
		t.Fatalf("stderr must contain the unmatched key, got %q", got.Stderr)
	}
}

// TestMock_StrictDoesNotBreakRegisteredLookups proves strict mode narrows ONLY the
// unmatched path. A guard that also perturbed matched lookups would be a
// regression, not a safeguard.
func TestMock_StrictDoesNotBreakRegisteredLookups(t *testing.T) {
	m := NewMockExecutor()
	m.StrictUnregistered = true
	m.RunResults["/usr/sbin/nftban:firewall:rebuild:--install-context"] = Result{
		ExitCode: 2,
		Stderr:   "fatal",
	}

	got := m.Run("/usr/sbin/nftban", "firewall", "rebuild", "--install-context")
	if got.ExitCode != 2 || got.Stderr != "fatal" {
		t.Fatalf("registered key must return its configured Result, got exit %d stderr %q",
			got.ExitCode, got.Stderr)
	}
	if u := m.UnmatchedCommands(); len(u) != 0 {
		t.Fatalf("a matched key must not be recorded as unmatched, got %v", u)
	}
}

// TestMock_UnmatchedRecordedInBothModes proves the record is available even to
// tests that do not opt into strict, so an existing suite can assert its fixtures
// actually matched without changing its failure semantics.
func TestMock_UnmatchedRecordedInBothModes(t *testing.T) {
	for _, strict := range []bool{false, true} {
		m := NewMockExecutor()
		m.StrictUnregistered = strict
		m.Run("nftban", "firewall", "rebuild")
		m.Run("systemctl", "is-active", "nftband")

		u := m.UnmatchedCommands()
		if len(u) != 2 {
			t.Fatalf("strict=%v: want 2 unmatched, got %d (%v)", strict, len(u), u)
		}
		if u[0] != "nftban:firewall:rebuild" || u[1] != "systemctl:is-active:nftband" {
			t.Fatalf("strict=%v: unmatched keys wrong or out of call order: %v", strict, u)
		}
	}
}

// TestMock_StaleKeyRegression is the NEGATIVE CONTROL. It reproduces the exact
// production regression: a fixture registered under the OLD argv while the code
// under test now passes an EXTRA argument.
//
// Permissive mode must exhibit the defect (exit 0 — the false pass), and strict
// mode must catch it. Asserting only the strict half would be vacuous: it would not
// prove the guard discriminates, only that it returns 255 for something.
func TestMock_StaleKeyRegression(t *testing.T) {
	const staleKey = "/usr/sbin/nftban:firewall:rebuild" // pre-v1.228.5 argv
	newArgv := []string{"firewall", "rebuild", "--install-context"}

	// Permissive: the fixture says exit 1, the stale key misses, and the caller
	// is told the command SUCCEEDED. This is the defect.
	permissive := NewMockExecutor()
	permissive.RunResults[staleKey] = Result{ExitCode: 1}
	if got := permissive.Run("/usr/sbin/nftban", newArgv...); got.ExitCode != 0 {
		t.Fatalf("negative control did not reproduce: want the false-success exit 0, got %d",
			got.ExitCode)
	}

	// Strict: same stale fixture, but the miss is now unmissable.
	strict := NewMockExecutor()
	strict.StrictUnregistered = true
	strict.RunResults[staleKey] = Result{ExitCode: 1}
	got := strict.Run("/usr/sbin/nftban", newArgv...)
	if got.ExitCode != 255 {
		t.Fatalf("strict mode failed to catch the stale key: got exit %d, want 255", got.ExitCode)
	}
	if u := strict.UnmatchedCommands(); len(u) != 1 || !strings.Contains(u[0], "--install-context") {
		t.Fatalf("unmatched record should name the NEW argv, got %v", u)
	}
}
