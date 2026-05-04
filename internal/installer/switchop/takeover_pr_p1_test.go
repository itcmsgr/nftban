// =============================================================================
// NFTBan v1.102.0 - PR-P1: ServiceResetFailed in DisableConflicts (#524)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-takeover-pr-p1-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-03"
// meta:description="Asserts DisableConflicts calls ServiceResetFailed after successful ServiceMask, for all conflict services, with non-fatal error handling. Closes #524."
// meta:inventory.files="internal/installer/switchop/takeover_pr_p1_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"errors"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// indexOf returns the index of the first command matching name+args[0]
// in mock.Commands, or -1 if absent. Sufficient for ordering assertions.
func indexOfCommand(cmds []executor.RecordedCommand, name string, firstArg string, unit string) int {
	for i, c := range cmds {
		if c.Name != name {
			continue
		}
		if len(c.Args) < 2 {
			continue
		}
		if c.Args[0] == firstArg && c.Args[1] == unit {
			return i
		}
	}
	return -1
}

// countResetFailed returns how many `systemctl reset-failed <any-unit>`
// commands were recorded.
func countResetFailed(cmds []executor.RecordedCommand) int {
	n := 0
	for _, c := range cmds {
		if c.Name == "systemctl" && len(c.Args) >= 1 && c.Args[0] == "reset-failed" {
			n++
		}
	}
	return n
}

// TestDisableConflicts_ResetFailed_CSFAndLFD verifies that, after the
// CSF + lfd takeover sequence, both units have a `systemctl reset-failed`
// command recorded.
func TestDisableConflicts_ResetFailed_CSFAndLFD(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["csf.service"] = true
	mock.Services["lfd.service"] = true

	conflicts := []detect.Conflict{
		{Name: "CSF", Service: "csf.service", Active: true},
		{Name: "LFD", Service: "lfd.service", Active: true},
	}

	if err := DisableConflicts(mock, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	if indexOfCommand(mock.Commands, "systemctl", "reset-failed", "csf.service") == -1 {
		t.Errorf("expected systemctl reset-failed csf.service after mask")
	}
	if indexOfCommand(mock.Commands, "systemctl", "reset-failed", "lfd.service") == -1 {
		t.Errorf("expected systemctl reset-failed lfd.service after mask")
	}
}

// TestDisableConflicts_ResetFailed_AfterMask_NotBefore verifies the
// ordering invariant — for each conflict, reset-failed must come after
// the matching mask call.
func TestDisableConflicts_ResetFailed_AfterMask_NotBefore(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["csf.service"] = true
	mock.Services["lfd.service"] = true

	conflicts := []detect.Conflict{
		{Name: "CSF", Service: "csf.service", Active: true},
		{Name: "LFD", Service: "lfd.service", Active: true},
	}

	if err := DisableConflicts(mock, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	for _, unit := range []string{"csf.service", "lfd.service"} {
		maskIdx := indexOfCommand(mock.Commands, "systemctl", "mask", unit)
		resetIdx := indexOfCommand(mock.Commands, "systemctl", "reset-failed", unit)
		if maskIdx == -1 {
			t.Errorf("%s: expected mask call recorded", unit)
			continue
		}
		if resetIdx == -1 {
			t.Errorf("%s: expected reset-failed call recorded", unit)
			continue
		}
		if resetIdx <= maskIdx {
			t.Errorf("%s: reset-failed (idx=%d) must come AFTER mask (idx=%d)",
				unit, resetIdx, maskIdx)
		}
	}
}

// TestDisableConflicts_ResetFailed_NotCalledIfMaskFails verifies the
// defensive guard — if ServiceMask returns an error for a unit, we
// must NOT call ServiceResetFailed for that unit.
func TestDisableConflicts_ResetFailed_NotCalledIfMaskFails(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["lfd.service"] = true
	// Inject mask failure — applies to ALL ServiceMask calls in this mock.
	mock.ServiceMaskErr = errors.New("simulated mask failure")

	conflicts := []detect.Conflict{
		{Name: "LFD", Service: "lfd.service", Active: true},
	}

	if err := DisableConflicts(mock, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts must not error on mask failure (warn-only): %v", err)
	}

	// mask was attempted
	if indexOfCommand(mock.Commands, "systemctl", "mask", "lfd.service") == -1 {
		t.Fatal("expected mask call to be attempted")
	}
	// reset-failed must NOT have been called
	if indexOfCommand(mock.Commands, "systemctl", "reset-failed", "lfd.service") != -1 {
		t.Error("reset-failed must NOT run when mask fails (defensive guard)")
	}
}

// TestDisableConflicts_ResetFailed_AppliesToAllConflicts verifies that
// reset-failed is not CSF-specific — non-CSF conflicts (firewalld) get
// the same treatment.
func TestDisableConflicts_ResetFailed_AppliesToAllConflicts(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["firewalld.service"] = true

	conflicts := []detect.Conflict{
		{Name: "firewalld", Service: "firewalld.service", Active: true},
	}

	if err := DisableConflicts(mock, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	if indexOfCommand(mock.Commands, "systemctl", "reset-failed", "firewalld.service") == -1 {
		t.Error("expected systemctl reset-failed firewalld.service (all-conflicts behavior, not CSF-only)")
	}
}

// TestDisableConflicts_ResetFailed_EmptyConflictsList verifies that
// an empty conflicts list produces zero reset-failed calls.
func TestDisableConflicts_ResetFailed_EmptyConflictsList(t *testing.T) {
	mock := executor.NewMockExecutor()

	if err := DisableConflicts(mock, []detect.Conflict{}, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	if got := countResetFailed(mock.Commands); got != 0 {
		t.Errorf("expected 0 reset-failed calls on empty conflicts, got %d", got)
	}
}

// TestDisableConflicts_ResetFailedError_NonFatal verifies that a
// reset-failed error from the executor is treated as cosmetic-only —
// DisableConflicts returns nil, and the call WAS attempted.
func TestDisableConflicts_ResetFailedError_NonFatal(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["lfd.service"] = true
	mock.ServiceResetFailedErr = errors.New("simulated reset-failed error")

	conflicts := []detect.Conflict{
		{Name: "LFD", Service: "lfd.service", Active: true},
	}

	if err := DisableConflicts(mock, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts must return nil even when reset-failed errors (cosmetic-only): %v", err)
	}

	// reset-failed call WAS attempted (even though it errored)
	if indexOfCommand(mock.Commands, "systemctl", "reset-failed", "lfd.service") == -1 {
		t.Error("reset-failed must be attempted even if it then errors")
	}
}
