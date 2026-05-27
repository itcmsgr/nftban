// =============================================================================
// NFTBan v1.73 - Installer Validate Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for post-install assertions and authority file write"
// meta:inventory.files="internal/installer/validate/validate_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validate

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

// seedNftbanConfContent returns a byte slice that satisfies PR-P2-6
// config_integrity_ok checks for nftban.conf: >= 256 bytes AND contains
// the SPDX-License-Identifier token.
func seedNftbanConfContent() []byte {
	body := "# SPDX-License-Identifier: MPL-2.0\n# NFTBan operator config\n"
	for len(body) < 400 {
		body += "# filler line\n"
	}
	return []byte(body)
}

// seedNftablesConfContent returns a byte slice that satisfies PR-P2-6
// config_integrity_ok checks for nftables.conf: >= 512 bytes AND
// contains both "#!/usr/sbin/nft" and "table ip nftban".
func seedNftablesConfContent() []byte {
	body := "#!/usr/sbin/nft -f\n# SPDX-License-Identifier: MPL-2.0\ntable ip nftban { }\n"
	for len(body) < 700 {
		body += "# filler line\n"
	}
	return []byte(body)
}

// seedCompletePayloadInventory populates the mock with every destination
// required by payload.VerifyInventory so assertPayloadInventory passes.
// Tests that want to exercise the inventory failure path can simply omit
// this helper or delete specific entries after calling it.
func seedCompletePayloadInventory(mock *executor.MockExecutor) {
	mock.Files["/usr/sbin/nftban"] = []byte("x")
	mock.Files["/usr/lib/nftban/bin/nftban-core"] = []byte("x")
	mock.Files["/usr/lib/nftban/bin/nftband"] = []byte("x")
	mock.Files["/usr/lib/nftban/bin/nftban-validate"] = []byte("x")
	mock.Files["/usr/lib/nftban/bin/nftban-installer"] = []byte("x")
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.98.2\n")
	// PR-P2-6: content must also satisfy config_integrity_ok — minimum
	// size + required-header tokens. Build fixtures above the floor.
	mock.Files["/etc/nftban/nftban.conf"] = seedNftbanConfContent()
	mock.Files["/etc/nftban/nftables.conf"] = seedNftablesConfContent()
	mock.Files["/etc/logrotate.d/nftban"] = []byte("x")
	// Shell dirs must exist AND contain at least one file — mock.FileExists
	// checks Files+Dirs; dirIsEmpty in payload.VerifyInventory opens the
	// real FS, so we use a tmpdir-backed approach in tests that care about
	// emptiness. For happy-path tests the Dirs marker is sufficient.
	for _, d := range []string{
		"/usr/lib/nftban/cli",
		"/usr/lib/nftban/core",
		"/usr/lib/nftban/lib",
		"/usr/lib/nftban/helpers",
		"/usr/lib/nftban/data",
		"/usr/lib/nftban/health",
	} {
		mock.Dirs[d] = true
	}
	// PR26.1: gatherer requires systemctl for FAILED-UNIT-POSTINSTALL-001
	// enumeration. Default exit-0 + empty stdout from MockExecutor means
	// "no failed nftban units" — happy path. Without this seeding the
	// gatherer fails closed (correct production behavior, but not the
	// scenario these existing happy-path tests exercise).
	mock.ExistingCommands["systemctl"] = true
	// v1.135: RunAssertions now includes core_timers_active_or_scheduled_ok —
	// mark the critical maintenance timer enabled+active so the happy-path mock
	// stays "all passing" (mirrors the payload_inventory_ok seeding pattern).
	mock.Services["nftban-maintenance.timer"] = true
	mock.ServicesEnabled["nftban-maintenance.timer"] = true
}

func TestRunAssertions_AllPass(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")
	seedCompletePayloadInventory(mock)

	results := RunAssertions(mock, 22, newTestLogger())

	if !AllPassed(results) {
		failed := FailedNames(results)
		t.Errorf("expected all assertions to pass, failed: %v", failed)
	}
}

// TestRunAssertions_PayloadInventoryMissing (R-3, issue #463): when a
// required canonical destination is absent (e.g. VERSION file missed by
// payload staging), the assertion suite must surface a FAIL — this is
// the pattern that would have caught the v1.98.1 P0.
func TestRunAssertions_PayloadInventoryMissing(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")
	seedCompletePayloadInventory(mock)
	// Simulate the v1.98.1 bug: VERSION file is missing from staged payload.
	delete(mock.Files, "/usr/lib/nftban/VERSION")

	results := RunAssertions(mock, 22, newTestLogger())

	if AllPassed(results) {
		t.Fatal("expected payload_inventory_ok to fail when VERSION is missing")
	}
	var inventoryFailed bool
	for _, r := range results {
		if r.Name == "payload_inventory_ok" && !r.Passed {
			inventoryFailed = true
			if r.Detail == "" {
				t.Error("expected Detail to describe missing paths")
			}
		}
	}
	if !inventoryFailed {
		t.Errorf("payload_inventory_ok assertion was not present or not failed, got: %v", FailedNames(results))
	}
}

func TestRunAssertions_DaemonDown(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = false
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")

	results := RunAssertions(mock, 22, newTestLogger())

	if AllPassed(results) {
		t.Error("expected some assertions to fail")
	}

	failed := FailedNames(results)
	found := false
	for _, name := range failed {
		if name == "daemon_active" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected daemon_active to fail, got: %v", failed)
	}
}

func TestRunAssertions_EmergencyTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.NftTables["inet:nftban_install_emergency"] = true // should fail
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")

	results := RunAssertions(mock, 22, newTestLogger())

	found := false
	for _, r := range results {
		if r.Name == "no_emergency_table" && !r.Passed {
			found = true
		}
	}
	if !found {
		t.Error("expected no_emergency_table assertion to fail")
	}
}

func TestRunAssertions_NoSSHPort(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")

	// sshPort=0 → skip SSH set check
	results := RunAssertions(mock, 0, newTestLogger())

	for _, r := range results {
		if r.Name == "ssh_in_set" && !r.Passed {
			t.Error("ssh_in_set should pass when sshPort=0")
		}
	}
}

func TestWriteAuthorityFiles(t *testing.T) {
	mock := executor.NewMockExecutor()

	WriteAuthorityFiles(mock, authority.Update, newTestLogger())

	data, err := mock.ReadFile("/var/lib/nftban/state/authority")
	if err != nil {
		t.Fatalf("expected authority file, got: %v", err)
	}
	if string(data) != "UPDATE\n" {
		t.Errorf("expected 'UPDATE\\n', got %q", string(data))
	}

	data, err = mock.ReadFile("/etc/nftban/.firewall_authority")
	if err != nil {
		t.Fatalf("expected legacy authority file, got: %v", err)
	}
	if string(data) != "nftban\n" {
		t.Errorf("expected 'nftban\\n', got %q", string(data))
	}
}

func TestWriteAuthorityFiles_Fresh(t *testing.T) {
	mock := executor.NewMockExecutor()

	WriteAuthorityFiles(mock, authority.Fresh, newTestLogger())

	data, err := mock.ReadFile("/var/lib/nftban/state/authority")
	if err != nil {
		t.Fatalf("expected authority file, got: %v", err)
	}
	if string(data) != "FRESH\n" {
		t.Errorf("expected 'FRESH\\n', got %q", string(data))
	}
}
