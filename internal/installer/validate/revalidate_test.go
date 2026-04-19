// =============================================================================
// NFTBan v1.98 - VALIDATE_1 → FIX → VALIDATE_2 State Machine Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-revalidate-test"
// meta:type="test"
// meta:version="1.98.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="NB-6 tests: bounded safe fix state machine for post-install validation"
// meta:inventory.files="internal/installer/validate/revalidate_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// NB-6 from V198_FOUNDATION_BATCH_AUDIT.md:
//   Test: VALIDATE_1 passes → no fix → success
//   Test: VALIDATE_1 fails → permissions enforce → VALIDATE_2 passes
//   Test: VALIDATE_1 fails → permissions enforce → VALIDATE_2 fails → DEGRADED
//   Assert: no external side-effects (no service disable, no package removal)
//   Assert: permissions enforce called at most once (INV-I-012)
//   Assert: final state determined by VALIDATE_2 result only (INV-I-013)
// =============================================================================

package validate

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
)

// healthyMock returns a mock where all assertions pass.
func healthyMock() *executor.MockExecutor {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")
	// v1.98.2 R-3: RunAssertions now includes payload_inventory_ok — seed the
	// canonical destinations so the happy-path mock remains "all passing".
	seedCompletePayloadInventory(mock)
	return mock
}

// NB-6 Test 1: VALIDATE_1 passes → no fix needed → success
func TestRevalidate_V1Passes_NoFix(t *testing.T) {
	mock := healthyMock()
	log := newTestLogger()

	result := RunWithBoundedFix(mock, 22, log)

	if !result.Validate1Passed {
		t.Error("VALIDATE_1 should pass")
	}
	if result.FixAttempted {
		t.Error("fix should NOT be attempted when VALIDATE_1 passes (INV-I-012)")
	}
	if !result.FinalPassed {
		t.Error("final result should be PASS")
	}

	// Verify no permissions enforce was called
	if mock.CommandCalled("permissions", "enforce") {
		t.Error("permissions enforce should NOT be called when VALIDATE_1 passes")
	}
}

// NB-6 Test 2: VALIDATE_1 fails → fix runs → VALIDATE_2 passes
func TestRevalidate_V1Fails_FixSucceeds_V2Passes(t *testing.T) {
	mock := healthyMock()
	// Break daemon assertion for V1, but make it "fixable"
	mock.Services["nftband.service"] = false
	// After permissions enforce, mock makes daemon active for V2
	// The callback key must match exactly how RunTimeout calls Run:
	// exec.RunTimeout(30s, "/usr/sbin/nftban", "permissions", "enforce")
	// → Run("/usr/sbin/nftban", "permissions", "enforce")
	mock.OnCommand(func() {
		mock.Services["nftband.service"] = true
	}, fhs.NftbanCLI, "permissions", "enforce")

	log := newTestLogger()
	result := RunWithBoundedFix(mock, 22, log)

	if result.Validate1Passed {
		t.Error("VALIDATE_1 should fail (daemon was down)")
	}
	if !result.FixAttempted {
		t.Error("fix should be attempted when VALIDATE_1 fails")
	}
	if result.FixExitCode != 0 {
		t.Errorf("fix exit code = %d; want 0", result.FixExitCode)
	}
	if !result.Validate2Passed {
		t.Error("VALIDATE_2 should pass (daemon fixed)")
	}
	if !result.FinalPassed {
		t.Error("final result should be PASS (determined by VALIDATE_2, INV-I-013)")
	}
}

// NB-6 Test 3: VALIDATE_1 fails → fix runs → VALIDATE_2 still fails → DEGRADED
func TestRevalidate_V1Fails_FixRuns_V2StillFails(t *testing.T) {
	mock := healthyMock()
	// Break daemon assertion — fix can't help (non-permission issue)
	mock.Services["nftband.service"] = false

	log := newTestLogger()
	result := RunWithBoundedFix(mock, 22, log)

	if result.Validate1Passed {
		t.Error("VALIDATE_1 should fail")
	}
	if !result.FixAttempted {
		t.Error("fix should be attempted")
	}
	if result.Validate2Passed {
		t.Error("VALIDATE_2 should still fail (daemon still down)")
	}
	if result.FinalPassed {
		t.Error("final result should be FAIL (DEGRADED)")
	}
	if len(result.FailedNames) == 0 {
		t.Error("failed names should be populated for DEGRADED state")
	}

	found := false
	for _, name := range result.FailedNames {
		if name == "daemon_active" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected daemon_active in failed names, got: %v", result.FailedNames)
	}
}

// NB-6 Assert: permissions enforce called at most once (INV-I-012)
func TestRevalidate_FixCalledAtMostOnce(t *testing.T) {
	mock := healthyMock()
	mock.Services["nftband.service"] = false

	log := newTestLogger()
	_ = RunWithBoundedFix(mock, 22, log)

	count := mock.CommandCallCount("permissions", "enforce")
	if count > 1 {
		t.Errorf("permissions enforce called %d times; must be at most 1 (INV-I-012)", count)
	}
}

// NB-6 Assert: no external side-effects
func TestRevalidate_NoDestructiveSideEffects(t *testing.T) {
	mock := healthyMock()
	mock.Services["nftband.service"] = false

	log := newTestLogger()
	_ = RunWithBoundedFix(mock, 22, log)

	// Verify none of the dangerous commands from "health fix all" were called
	dangerous := [][]string{
		{"health", "fix", "all"},
		{"apt-get", "remove"},
		{"systemctl", "disable"},
		{"csf", "-x"},
		{"geoip", "update"},
		{"panel", "enable"},
	}

	for _, cmd := range dangerous {
		if mock.CommandCalled(cmd...) {
			t.Errorf("DANGEROUS: %v should NEVER be called from bounded safe fix", cmd)
		}
	}
}
