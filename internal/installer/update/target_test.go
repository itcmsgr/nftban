// =============================================================================
// NFTBan v1.99 PR-17 — Target Detection Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-target-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Unit tests for package-install target + origin detection + recovery plan"
// meta:inventory.files="internal/installer/update/target_test.go"
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
)

// DetectInstallOrigin ────────────────────────────────────────────────────────

func TestDetectInstallOrigin_RPM(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "nftban-core-1.98.2-1.el9.x86_64\n",
	}

	got := DetectInstallOrigin(mock, newTestLogger())
	if got != "rpm" {
		t.Errorf("DetectInstallOrigin = %q; want rpm", got)
	}
}

func TestDetectInstallOrigin_DEB(t *testing.T) {
	mock := executor.NewMockExecutor()
	// rpm not present — simulated as exit 127.
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "Package: nftban-core\nVersion: 1.98.2\n",
	}

	got := DetectInstallOrigin(mock, newTestLogger())
	if got != "deb" {
		t.Errorf("DetectInstallOrigin = %q; want deb", got)
	}
}

func TestDetectInstallOrigin_Source(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{ExitCode: 127}
	mock.Env["NFTBAN_SOURCE_DIR"] = "/opt/nftban-src"

	got := DetectInstallOrigin(mock, newTestLogger())
	if got != "source" {
		t.Errorf("DetectInstallOrigin = %q; want source", got)
	}
}

func TestDetectInstallOrigin_Unknown(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No package manager ownership, no source env.
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{ExitCode: 127}

	got := DetectInstallOrigin(mock, newTestLogger())
	if got != "" {
		t.Errorf("DetectInstallOrigin = %q; want empty", got)
	}
}

// DetectPackageTarget ───────────────────────────────────────────────────────

func TestDetectPackageTarget_RPM(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["rpm:-q:--queryformat:%{VERSION}:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "1.98.2",
	}
	mock.RunResults["rpm:-q:--queryformat:%{VERSION}:nftban"] = executor.Result{ExitCode: 1}

	got, err := DetectPackageTarget(mock, "rpm", newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "1.98.2" {
		t.Errorf("DetectPackageTarget = %q; want 1.98.2", got)
	}
}

func TestDetectPackageTarget_DEB(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "Package: nftban-core\nStatus: install ok installed\nVersion: 1.98.2\n",
	}

	got, err := DetectPackageTarget(mock, "deb", newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "1.98.2" {
		t.Errorf("DetectPackageTarget = %q; want 1.98.2", got)
	}
}

func TestDetectPackageTarget_NotOwned_RPM(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["rpm:-q:--queryformat:%{VERSION}:nftban-core"] = executor.Result{
		ExitCode: 1,
		Stdout:   "package nftban-core is not installed",
	}

	got, _ := DetectPackageTarget(mock, "rpm", newTestLogger())
	if got != "" {
		t.Errorf("not-installed rpm should return empty, got %q", got)
	}
}

func TestDetectPackageTarget_UnknownOrigin(t *testing.T) {
	mock := executor.NewMockExecutor()

	got, err := DetectPackageTarget(mock, "", newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "" {
		t.Errorf("unknown origin should return empty, got %q", got)
	}
}

// DetectVersions — PR-17 package detection integration ──────────────────────

func TestDetectVersions_PackageDebFallback(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.98.2\n")
	// No source dir; deb origin; package manager reports target 1.99.0.
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "Package: nftban-core\nVersion: 1.99.0\n",
	}

	current, target, err := DetectVersions(mock, "", "deb", newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if current != "1.98.2" {
		t.Errorf("current = %q; want 1.98.2", current)
	}
	if target != "1.99.0" {
		t.Errorf("target = %q; want 1.99.0 (from dpkg -s)", target)
	}
}

func TestDetectVersions_SourceOverridesPackage(t *testing.T) {
	// Source dir takes precedence even when package origin is declared —
	// the operator's explicit --source-dir wins. Prevents surprise apply
	// against staged package when operator clearly wanted source tree.
	mock := executor.NewMockExecutor()
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.98.2\n")
	mock.Files["/tmp/src/VERSION"] = []byte("1.99.0\n")
	mock.RunResults["rpm:-q:--queryformat:%{VERSION}:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "1.98.5", // different from source tree
	}

	_, target, err := DetectVersions(mock, "/tmp/src", "rpm", newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if target != "1.99.0" {
		t.Errorf("source-tree should win over package: target = %q; want 1.99.0", target)
	}
}

// Preflight — P-6 rebuild_recovery_available ────────────────────────────────

func TestPreflight_RecoveryUnavailable_IsWarning(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	// Break recovery: no ip nftban table.
	delete(mock.NftTables, "ip:nftban")

	res := Preflight(mock, newTestLogger(), "source")

	// P-1 authority_nftban is critical + fails. That's expected.
	// P-6 rebuild_recovery_available is warning + fails. Also expected.
	var p6Failed bool
	for _, c := range res.Checks {
		if c.Name == "rebuild_recovery_available" && !c.Passed {
			p6Failed = true
			if c.Severity != "warning" {
				t.Errorf("P-6 severity = %q; want warning", c.Severity)
			}
		}
	}
	if !p6Failed {
		t.Error("P-6 rebuild_recovery_available should report a failed warning check")
	}
}

// Preflight — P-7 install_origin_coherent ───────────────────────────────────

func TestPreflight_OriginCoherent_Match(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "Version: 1.98.2\n",
	}
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{ExitCode: 127}

	res := Preflight(mock, newTestLogger(), "deb")

	for _, c := range res.Checks {
		if c.Name == "install_origin_coherent" && !c.Passed {
			t.Errorf("P-7 should pass when declared origin matches detected: %s", c.Detail)
		}
	}
}

func TestPreflight_OriginCoherent_Mismatch_IsWarning(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	// Host is deb but operator declared rpm.
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{
		ExitCode: 0,
		Stdout:   "Version: 1.98.2\n",
	}

	res := Preflight(mock, newTestLogger(), "rpm")

	var p7Failed bool
	for _, c := range res.Checks {
		if c.Name == "install_origin_coherent" && !c.Passed {
			p7Failed = true
			if c.Severity != "warning" {
				t.Errorf("P-7 severity = %q; want warning", c.Severity)
			}
			if !strings.Contains(c.Detail, "rpm") || !strings.Contains(c.Detail, "deb") {
				t.Errorf("P-7 detail should mention both declared and detected: %s", c.Detail)
			}
		}
	}
	if !p7Failed {
		t.Error("P-7 install_origin_coherent should report a failed warning on mismatch")
	}
}

// BuildRecoveryPlan ─────────────────────────────────────────────────────────

func TestBuildRecoveryPlan_HappyPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)

	r := BuildRecoveryPlan(mock)
	if !r.Available {
		t.Error("recovery should be Available when prerequisites met")
	}
	if r.Mechanism != "rebuild" {
		t.Errorf("mechanism = %q; want rebuild", r.Mechanism)
	}
}

func TestBuildRecoveryPlan_NoState_NotesFreshRecovery(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	delete(mock.Files, "/var/lib/nftban/state/install_state")

	r := BuildRecoveryPlan(mock)
	if !r.Available {
		t.Error("recovery with no prior state should be Available (fresh)")
	}
	var foundFreshNote bool
	for _, n := range r.Notes {
		if strings.Contains(n, "no prior install_state") {
			foundFreshNote = true
		}
	}
	if !foundFreshNote {
		t.Error("notes should mention fresh-recovery case")
	}
}

func TestBuildRecoveryPlan_InProgressState_Unavailable(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyPreflight(mock)
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("PREPARE_COMPLETE\n")

	r := BuildRecoveryPlan(mock)
	if r.Available {
		t.Error("recovery should be Unavailable when prior state is non-terminal")
	}
}
