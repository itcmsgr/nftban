// =============================================================================
// NFTBan v1.99 PR-16 — Update Package Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Unit tests for update preflight + plan + version detection"
// meta:inventory.files="internal/installer/update/update_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package update

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

// seedHappyPreflight populates a mock with all P-1..P-5 passing.
func seedHappyPreflight(mock *executor.MockExecutor) {
	mock.NftTables["ip:nftban"] = true
	mock.Services["nftband.service"] = true
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.98.2\n")
	// nft in PATH — mock the sh -c command-v check
	mock.RunResults["sh:-c:command -v nft >/dev/null 2>&1"] = executor.Result{ExitCode: 0}
	// state marker is terminal
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED\n")
}

// Tests for Preflight ────────────────────────────────────────────────────────

func TestPreflight_AllPass(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)

	res := Preflight(mock, newTestLogger())
	if !res.Passed {
		t.Errorf("expected preflight to pass, got failing checks:")
		for _, c := range res.Checks {
			if !c.Passed {
				t.Logf("  %s: %s", c.Name, c.Detail)
			}
		}
	}
	// All 5 checks should be present regardless of outcome.
	if len(res.Checks) != 5 {
		t.Errorf("expected 5 preflight checks, got %d", len(res.Checks))
	}
}

// G3-U4: authority failure must fail preflight critically.
// Covers the INV-U-003 intuition: if nftban doesn't own authority, update
// must not enter a transition that might implicitly take it.
func TestPreflight_NoAuthority_Fails(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	delete(mock.NftTables, "ip:nftban")

	res := Preflight(mock, newTestLogger())
	if res.Passed {
		t.Error("preflight should fail when nftban does not own authority")
	}
	if !hasCheckFailed(res, "authority_nftban") {
		t.Error("authority_nftban check should be failed")
	}
}

func TestPreflight_DaemonDown_Fails(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	mock.Services["nftband.service"] = false

	res := Preflight(mock, newTestLogger())
	if res.Passed {
		t.Error("preflight should fail when nftband is down")
	}
	if !hasCheckFailed(res, "service_nftband_active") {
		t.Error("service_nftband_active check should be failed")
	}
}

func TestPreflight_MissingVERSION_Fails(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	delete(mock.Files, "/usr/lib/nftban/VERSION")

	res := Preflight(mock, newTestLogger())
	if res.Passed {
		t.Error("preflight should fail when VERSION is missing")
	}
	if !hasCheckFailed(res, "artifact_version_file") {
		t.Error("artifact_version_file check should be failed")
	}
}

func TestPreflight_MissingNft_Fails(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	mock.RunResults["sh:-c:command -v nft >/dev/null 2>&1"] = executor.Result{ExitCode: 127}

	res := Preflight(mock, newTestLogger())
	if res.Passed {
		t.Error("preflight should fail when nft is missing")
	}
	if !hasCheckFailed(res, "dependency_nft") {
		t.Error("dependency_nft check should be failed")
	}
}

// A stale in-progress marker is a WARNING (non-critical) — preflight still
// passes but the plan should carry a warning downstream.
func TestPreflight_StaleInProgress_IsWarning(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("PREPARE_COMPLETE\n")

	res := Preflight(mock, newTestLogger())
	if !res.Passed {
		t.Error("preflight should still pass when only a warning-severity check fails")
	}
	var found bool
	for _, c := range res.Checks {
		if c.Name == "state_no_stale_in_progress" && !c.Passed {
			found = true
			if c.Severity != "warning" {
				t.Errorf("stale state check severity = %q; want warning", c.Severity)
			}
		}
	}
	if !found {
		t.Error("state_no_stale_in_progress should report a failed warning check")
	}
}

// Tests for DetectVersions ──────────────────────────────────────────────────

func TestDetectVersions_HappyPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.98.2\n")
	mock.Files["/tmp/srcdir/VERSION"] = []byte("1.99.0\n")

	current, target, err := DetectVersions(mock, "/tmp/srcdir", newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if current != "1.98.2" {
		t.Errorf("current = %q; want 1.98.2", current)
	}
	if target != "1.99.0" {
		t.Errorf("target = %q; want 1.99.0", target)
	}
}

func TestDetectVersions_MissingCurrent_Errors(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Deliberately no /usr/lib/nftban/VERSION seeded.

	_, _, err := DetectVersions(mock, "", newTestLogger())
	if err == nil {
		t.Error("expected error when VERSION file is missing")
	}
}

func TestDetectVersions_MissingTarget_IsNonFatal(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.98.2\n")

	current, target, err := DetectVersions(mock, "", newTestLogger())
	if err != nil {
		t.Fatalf("missing target should be non-fatal for PR-16, got: %v", err)
	}
	if current != "1.98.2" {
		t.Errorf("current = %q; want 1.98.2", current)
	}
	if target != "" {
		t.Errorf("target = %q; want empty (package-install detection is PR-17)", target)
	}
}

// Tests for BuildPlan + rendering ───────────────────────────────────────────

func TestBuildPlan_NeedsUpdate(t *testing.T) {
	pre := &PreflightResult{Passed: true}
	p := BuildPlan(pre, "1.98.2", "1.99.0", "source")

	if p.SchemaVersion != PlanSchemaVersion {
		t.Errorf("schema_version = %q; want %q", p.SchemaVersion, PlanSchemaVersion)
	}
	if !p.NeedsUpdate {
		t.Error("plan should say NeedsUpdate when current != target")
	}
	if len(p.Actions) == 0 {
		t.Error("plan should carry at least one Action describing the architectural model")
	}
	// INV-U-001 must be visible in the rendered plan.
	var foundInvariantNote bool
	for _, a := range p.Actions {
		if strings.Contains(a, "INV-U-001") {
			foundInvariantNote = true
		}
	}
	if !foundInvariantNote {
		t.Error("Actions should reference INV-U-001 so operators see the architectural constraint")
	}
}

func TestBuildPlan_SameVersion_NoUpdateNeeded(t *testing.T) {
	pre := &PreflightResult{Passed: true}
	p := BuildPlan(pre, "1.98.2", "1.98.2", "source")

	if p.NeedsUpdate {
		t.Error("NeedsUpdate should be false when current == target")
	}
}

func TestBuildPlan_EmptyTarget_WarnsNotFatal(t *testing.T) {
	pre := &PreflightResult{Passed: true}
	p := BuildPlan(pre, "1.98.2", "", "rpm")

	if p.NeedsUpdate {
		t.Error("empty target must not imply NeedsUpdate=true")
	}
	var foundWarning bool
	for _, w := range p.Warnings {
		if strings.Contains(w, "target version not detected") {
			foundWarning = true
		}
	}
	if !foundWarning {
		t.Error("empty target should produce an operator-visible warning")
	}
}

func TestBuildPlan_PreflightFailed_AddsWarning(t *testing.T) {
	pre := &PreflightResult{Passed: false}
	p := BuildPlan(pre, "1.98.2", "1.99.0", "source")

	var found bool
	for _, w := range p.Warnings {
		if strings.Contains(w, "preflight failed") {
			found = true
		}
	}
	if !found {
		t.Error("failing preflight should add a warning to the plan")
	}
}

func TestPlan_JSON_RoundTrip(t *testing.T) {
	pre := &PreflightResult{Passed: true, Checks: []PreflightCheck{{Name: "x", Passed: true, Severity: "critical"}}}
	p := BuildPlan(pre, "1.98.2", "1.99.0", "source")

	data, err := p.JSON()
	if err != nil {
		t.Fatalf("JSON encode: %v", err)
	}
	out := string(data)
	// Contract surface — must contain these field names.
	for _, needle := range []string{
		`"schema_version"`,
		`"current_version"`,
		`"target_version"`,
		`"needs_update"`,
		`"preflight"`,
	} {
		if !strings.Contains(out, needle) {
			t.Errorf("JSON output missing %s:\n%s", needle, out)
		}
	}
}

// Helpers ────────────────────────────────────────────────────────────────────

func hasCheckFailed(res *PreflightResult, name string) bool {
	for _, c := range res.Checks {
		if c.Name == name && !c.Passed {
			return true
		}
	}
	return false
}
