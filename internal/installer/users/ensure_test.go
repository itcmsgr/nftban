// =============================================================================
// NFTBan v1.98.x - Installer User/Group Ensure Tests (PR-14-pre G-14-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-users-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Tests for source-install user/group creation"
// meta:inventory.files="internal/installer/users/ensure_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package users

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("", false)
}

// countCommand returns how many times the mock saw a given command name.
func countCommand(mock *executor.MockExecutor, name string) int {
	n := 0
	for _, c := range mock.Commands {
		if c.Name == name {
			n++
		}
	}
	return n
}

// hasArg returns true if any invocation of name includes the given arg.
func hasArg(mock *executor.MockExecutor, name, arg string) bool {
	for _, c := range mock.Commands {
		if c.Name != name {
			continue
		}
		for _, a := range c.Args {
			if a == arg {
				return true
			}
		}
	}
	return false
}

func TestEnsure_DebianFamily_CreatesAllEntities(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Nothing exists yet — fresh VM state
	mock.ExistingCommands["addgroup"] = true
	mock.ExistingCommands["adduser"] = true
	mock.ExistingCommands["usermod"] = true
	mock.ExistingCommands["id"] = true

	distro := &detect.DistroInfo{ID: "ubuntu", VersionID: "24.04"}
	if err := Ensure(mock, distro, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// 3 groups created (via addgroup --system); nftban-panel retired in v1.137
	if got := countCommand(mock, "addgroup"); got != 3 {
		t.Errorf("addgroup: got %d calls, want 3", got)
	}
	// 1 user created (via adduser)
	if got := countCommand(mock, "adduser"); got != 1 {
		t.Errorf("adduser: got %d calls, want 1", got)
	}
	// 1 usermod -a -G to add root to nftban
	if !hasArg(mock, "usermod", "-a") || !hasArg(mock, "usermod", "-G") {
		t.Errorf("usermod -a -G not invoked")
	}
	// Debian-family: must NOT invoke useradd or groupadd
	if countCommand(mock, "useradd") != 0 {
		t.Errorf("debian family unexpectedly used useradd")
	}
	if countCommand(mock, "groupadd") != 0 {
		t.Errorf("debian family unexpectedly used groupadd")
	}
}

func TestEnsure_RHELFamily_CreatesAllEntities(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["groupadd"] = true
	mock.ExistingCommands["useradd"] = true
	mock.ExistingCommands["usermod"] = true
	mock.ExistingCommands["id"] = true

	distro := &detect.DistroInfo{ID: "almalinux", VersionID: "9"}
	if err := Ensure(mock, distro, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if got := countCommand(mock, "groupadd"); got != 3 {
		t.Errorf("groupadd: got %d calls, want 3", got)
	}
	if got := countCommand(mock, "useradd"); got != 1 {
		t.Errorf("useradd: got %d calls, want 1", got)
	}
	// RHEL-family: must NOT invoke adduser/addgroup (Debian-specific)
	if countCommand(mock, "adduser") != 0 {
		t.Errorf("rhel family unexpectedly used adduser")
	}
	if countCommand(mock, "addgroup") != 0 {
		t.Errorf("rhel family unexpectedly used addgroup")
	}
}

func TestEnsure_Idempotent_SkipsExisting(t *testing.T) {
	mock := executor.NewMockExecutor()
	// All groups + user already exist — e.g., re-running after a prior install
	for _, g := range systemGroups {
		mock.Groups[g] = true
	}
	mock.Users["nftban"] = true
	// Simulate root already in nftban group so usermod is skipped.
	// Mock.RunResults is keyed by "name:arg1:arg2".
	mock.RunResults["id:-nG:root"] = executor.Result{
		ExitCode: 0,
		Stdout:   "root wheel nftban",
	}

	distro := &detect.DistroInfo{ID: "ubuntu", VersionID: "24.04"}
	if err := Ensure(mock, distro, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Nothing should have been created
	if got := countCommand(mock, "addgroup"); got != 0 {
		t.Errorf("idempotent run still called addgroup %d times", got)
	}
	if got := countCommand(mock, "adduser"); got != 0 {
		t.Errorf("idempotent run still called adduser %d times", got)
	}
	if got := countCommand(mock, "usermod"); got != 0 {
		t.Errorf("idempotent run still called usermod %d times", got)
	}
}

func TestEnsure_NilDistro_ReturnsError(t *testing.T) {
	mock := executor.NewMockExecutor()
	err := Ensure(mock, nil, newTestLogger())
	if err == nil {
		t.Fatalf("expected error for nil distro, got nil")
	}
}

func TestEnsure_UnknownDistro_FallsBackToRHEL(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["groupadd"] = true
	mock.ExistingCommands["useradd"] = true
	mock.ExistingCommands["usermod"] = true
	mock.ExistingCommands["id"] = true

	// Unknown distro should fall through to rhel-family commands (more portable)
	distro := &detect.DistroInfo{ID: "exotic-linux", VersionID: "1.0"}
	if err := Ensure(mock, distro, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if countCommand(mock, "groupadd") != 3 {
		t.Errorf("unknown distro did not fall back to groupadd")
	}
	if countCommand(mock, "adduser") != 0 {
		t.Errorf("unknown distro used adduser (debian-only)")
	}
}

func TestDistroFamily(t *testing.T) {
	cases := map[string]string{
		"debian":    "debian",
		"ubuntu":    "debian",
		"UBUNTU":    "debian", // case-insensitive
		"rhel":      "rhel",
		"centos":    "rhel",
		"fedora":    "rhel",
		"rocky":     "rhel",
		"almalinux": "rhel",
		"arch":      "rhel", // unknown fallback
		"":          "rhel",
	}
	for id, want := range cases {
		if got := distroFamily(id); got != want {
			t.Errorf("distroFamily(%q) = %q, want %q", id, got, want)
		}
	}
}
