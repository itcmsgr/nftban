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

func TestRunAssertions_AllPass(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")

	results := RunAssertions(mock, 22, newTestLogger())

	if !AllPassed(results) {
		failed := FailedNames(results)
		t.Errorf("expected all assertions to pass, failed: %v", failed)
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
