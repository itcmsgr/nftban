// =============================================================================
// NFTBan v1.76.0 - Installer Dependency Auto-Install Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-deps-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="Tests for dependency auto-install logic"
// meta:inventory.files="internal/installer/deps/deps_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package deps

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("", false)
}

func TestInstallMissing_AllPresent(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		mock.ExistingCommands[d.cmd] = true
	}

	distro := &detect.DistroInfo{ID: "ubuntu", VersionID: "24.04"}
	err := InstallMissing(mock, distro, newTestLogger())
	if err != nil {
		t.Fatalf("expected no error when all deps present, got: %v", err)
	}

	// No install commands should have been issued
	for _, cmd := range mock.Commands {
		if cmd.Name == "apt-get" || cmd.Name == "dnf" || cmd.Name == "yum" {
			t.Errorf("unexpected package install command: %s", cmd.Name)
		}
	}
}

func TestInstallMissing_DEB_CallsAptGet(t *testing.T) {
	mock := executor.NewMockExecutor()
	// All deps present except jq and bc
	for _, d := range requiredDeps {
		mock.ExistingCommands[d.cmd] = true
	}
	delete(mock.ExistingCommands, "jq")
	delete(mock.ExistingCommands, "bc")
	mock.ExistingCommands["apt-get"] = true

	// Simulate successful install — jq and bc become available after apt-get
	// We pre-set them back so the post-install check passes
	// (In reality, apt-get would install them; here we just verify the command is called)
	mock.ExistingCommands["jq"] = true
	mock.ExistingCommands["bc"] = true

	// Temporarily remove them for the initial check, then re-add for post-check.
	// The mock always returns the current state, so we need a trick:
	// Just verify the command is called. Since they're already present,
	// InstallMissing won't try to install. So we test indirectly.

	// Reset: make jq/bc genuinely missing
	mock2 := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "jq" && d.cmd != "bc" {
			mock2.ExistingCommands[d.cmd] = true
		}
	}
	mock2.ExistingCommands["apt-get"] = true

	distro2 := &detect.DistroInfo{ID: "debian", VersionID: "12"}
	// This will fail verification (jq still missing after install attempt)
	// but we can check the right command was called
	_ = InstallMissing(mock2, distro2, newTestLogger())

	foundApt := false
	for _, cmd := range mock2.Commands {
		if cmd.Name == "apt-get" && len(cmd.Args) > 0 && cmd.Args[0] == "install" {
			foundApt = true
			fullArgs := strings.Join(cmd.Args, " ")
			if !strings.Contains(fullArgs, "jq") {
				t.Errorf("expected jq in apt-get args, got: %s", fullArgs)
			}
			if !strings.Contains(fullArgs, "bc") {
				t.Errorf("expected bc in apt-get args, got: %s", fullArgs)
			}
		}
	}
	if !foundApt {
		t.Error("expected apt-get install to be called")
	}
}

func TestInstallMissing_RPM_CallsDnf(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "socat" {
			mock.ExistingCommands[d.cmd] = true
		}
	}
	mock.ExistingCommands["dnf"] = true

	distro := &detect.DistroInfo{ID: "almalinux", VersionID: "9"}
	_ = InstallMissing(mock, distro, newTestLogger())

	foundDnf := false
	for _, cmd := range mock.Commands {
		if cmd.Name == "dnf" && len(cmd.Args) > 0 && cmd.Args[0] == "install" {
			foundDnf = true
			fullArgs := strings.Join(cmd.Args, " ")
			if !strings.Contains(fullArgs, "socat") {
				t.Errorf("expected socat in dnf args, got: %s", fullArgs)
			}
		}
	}
	if !foundDnf {
		t.Error("expected dnf install to be called for AlmaLinux")
	}
}

func TestInstallMissing_RPM_FallbackToYum(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "jq" {
			mock.ExistingCommands[d.cmd] = true
		}
	}
	// dnf NOT available, yum IS
	mock.ExistingCommands["yum"] = true

	distro := &detect.DistroInfo{ID: "centos", VersionID: "7"}
	_ = InstallMissing(mock, distro, newTestLogger())

	foundYum := false
	for _, cmd := range mock.Commands {
		if cmd.Name == "yum" {
			foundYum = true
		}
	}
	if !foundYum {
		t.Error("expected yum to be called when dnf unavailable")
	}
}

func TestInstallMissing_CriticalStillMissing(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "jq" {
			mock.ExistingCommands[d.cmd] = true
		}
	}
	mock.ExistingCommands["apt-get"] = true
	// jq remains missing after install attempt

	distro := &detect.DistroInfo{ID: "debian", VersionID: "12"}
	err := InstallMissing(mock, distro, newTestLogger())
	if err == nil {
		t.Fatal("expected error when critical dep still missing")
	}
	if !strings.Contains(err.Error(), "jq") {
		t.Errorf("expected error to mention jq, got: %v", err)
	}
}

func TestInstallMissing_OptionalStillMissing_NoError(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "bc" { // bc is non-critical
			mock.ExistingCommands[d.cmd] = true
		}
	}
	mock.ExistingCommands["apt-get"] = true
	// bc remains missing but it's non-critical

	distro := &detect.DistroInfo{ID: "ubuntu", VersionID: "24.04"}
	err := InstallMissing(mock, distro, newTestLogger())
	if err != nil {
		t.Fatalf("expected no error for optional dep missing, got: %v", err)
	}
}

func TestDedup(t *testing.T) {
	input := []string{"jq", "bc", "jq", "gawk", "bc"}
	got := dedup(input)
	if len(got) != 3 {
		t.Fatalf("expected 3 unique items, got %d: %v", len(got), got)
	}
	if got[0] != "jq" || got[1] != "bc" || got[2] != "gawk" {
		t.Errorf("unexpected order: %v", got)
	}
}

func TestIsRPMFamily(t *testing.T) {
	rpms := []string{"centos", "rhel", "rocky", "almalinux", "fedora"}
	for _, id := range rpms {
		if !isRPMFamily(id) {
			t.Errorf("expected %s to be RPM family", id)
		}
	}
	debs := []string{"ubuntu", "debian", "linuxmint"}
	for _, id := range debs {
		if isRPMFamily(id) {
			t.Errorf("expected %s to NOT be RPM family", id)
		}
	}
}

// PR-P4 (issue #467): apt-get update preflight before apt-get install.

// TestInstallMissing_DEB_RunsAptGetUpdateBeforeInstall verifies that the
// DEB path issues `apt-get update` BEFORE `apt-get install` so a stale
// apt index does not cause a misleading "Unable to locate package".
func TestInstallMissing_DEB_RunsAptGetUpdateBeforeInstall(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "jq" {
			mock.ExistingCommands[d.cmd] = true
		}
	}
	mock.ExistingCommands["apt-get"] = true

	distro := &detect.DistroInfo{ID: "ubuntu", VersionID: "22.04"}
	// jq remains "missing" so the post-install check returns critical-still-missing,
	// but that's fine — we only assert the call ordering.
	_ = InstallMissing(mock, distro, newTestLogger())

	updateIdx := -1
	installIdx := -1
	for i, cmd := range mock.Commands {
		if cmd.Name != "apt-get" {
			continue
		}
		if len(cmd.Args) > 0 && cmd.Args[0] == "update" && updateIdx == -1 {
			updateIdx = i
		}
		if len(cmd.Args) > 0 && cmd.Args[0] == "install" && installIdx == -1 {
			installIdx = i
		}
	}
	if updateIdx == -1 {
		t.Fatal("expected apt-get update to be called as preflight")
	}
	if installIdx == -1 {
		t.Fatal("expected apt-get install to be called")
	}
	if updateIdx >= installIdx {
		t.Errorf("apt-get update must precede apt-get install (updateIdx=%d, installIdx=%d)", updateIdx, installIdx)
	}
}

// TestInstallMissing_DEB_AptGetUpdateFailureIsFatal verifies that when the
// apt-get update preflight fails, InstallMissing returns a clear preflight
// error AND apt-get install is NOT attempted.
func TestInstallMissing_DEB_AptGetUpdateFailureIsFatal(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "jq" {
			mock.ExistingCommands[d.cmd] = true
		}
	}
	mock.ExistingCommands["apt-get"] = true

	// Seed apt-get update to fail (simulates network-down / repo unreachable).
	mock.RunResults["apt-get:update"] = executor.Result{
		ExitCode: 100,
		Stderr:   "E: Could not resolve 'archive.ubuntu.com'",
	}

	distro := &detect.DistroInfo{ID: "debian", VersionID: "12"}
	err := InstallMissing(mock, distro, newTestLogger())
	if err == nil {
		t.Fatal("expected error when apt-get update preflight fails (critical dep missing path)")
	}

	// Find apt-get update + assert apt-get install was NOT attempted.
	sawUpdate := false
	sawInstall := false
	for _, cmd := range mock.Commands {
		if cmd.Name != "apt-get" {
			continue
		}
		if len(cmd.Args) > 0 && cmd.Args[0] == "update" {
			sawUpdate = true
		}
		if len(cmd.Args) > 0 && cmd.Args[0] == "install" {
			sawInstall = true
		}
	}
	if !sawUpdate {
		t.Fatal("expected apt-get update to be attempted")
	}
	if sawInstall {
		t.Error("apt-get install must NOT run after apt-get update preflight failure")
	}

	// Direct helper check: aptGetUpdate must surface a clear preflight error.
	directErr := aptGetUpdate(mock, newTestLogger())
	if directErr == nil {
		t.Fatal("expected aptGetUpdate to return an error when apt-get exits non-zero")
	}
	msg := directErr.Error()
	if !strings.Contains(msg, "apt-get update preflight failed") {
		t.Errorf("expected error to contain 'apt-get update preflight failed', got: %v", directErr)
	}
	if !strings.Contains(msg, "100") {
		t.Errorf("expected error to contain exit code 100, got: %v", directErr)
	}
	if !strings.Contains(msg, "archive.ubuntu.com") {
		t.Errorf("expected error to contain stderr text, got: %v", directErr)
	}
}

// TestInstallMissing_RPM_DoesNotRunAptGetUpdate verifies that the RPM/DNF
// path is unaffected by the PR-P4 preflight (apt-get update only applies
// to the DEB family).
func TestInstallMissing_RPM_DoesNotRunAptGetUpdate(t *testing.T) {
	mock := executor.NewMockExecutor()
	for _, d := range requiredDeps {
		if d.cmd != "socat" {
			mock.ExistingCommands[d.cmd] = true
		}
	}
	mock.ExistingCommands["dnf"] = true

	distro := &detect.DistroInfo{ID: "almalinux", VersionID: "9"}
	_ = InstallMissing(mock, distro, newTestLogger())

	for _, cmd := range mock.Commands {
		if cmd.Name == "apt-get" {
			t.Errorf("RPM path must not call apt-get (got: %s %v)", cmd.Name, cmd.Args)
		}
	}
}
