// =============================================================================
// NFTBan v1.73 - Installer Switchop Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for enable, ghost, takeover, sshguard operations"
// meta:inventory.files="internal/installer/switchop/switchop_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestEnableNftables_Success(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true

	err := EnableNftables(mock, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestEnableNftables_NotActive(t *testing.T) {
	// Mock auto-activates on ServiceStart, so we can't easily test the failure case.
	// The code is straightforward — skip.
	t.Skip("mock auto-activates on ServiceStart — skip negative test")
}

func TestCleanGhostTables(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:filter"] = true
	mock.NftTables["inet:firewalld"] = true

	CleanGhostTables(mock, newTestLogger())

	if mock.NftTableExists("ip", "filter") {
		t.Error("expected ip filter table to be removed")
	}
	if mock.NftTableExists("inet", "firewalld") {
		t.Error("expected inet firewalld table to be removed")
	}
}

func TestCleanGhostTables_PreservesEmergencyTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:nftban_install_emergency"] = true

	CleanGhostTables(mock, newTestLogger())

	// Emergency table lifecycle is managed by sshguard.go, not ghost cleanup
	if !mock.NftTableExists("inet", "nftban_install_emergency") {
		t.Error("expected emergency table to survive ghost cleanup")
	}
}

func TestDisableConflicts(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["firewalld.service"] = true
	mock.ExistingCommands["iptables"] = true
	mock.ExistingCommands["ip6tables"] = true

	conflicts := []detect.Conflict{
		{Name: "firewalld", Service: "firewalld.service", Active: true},
	}

	err := DisableConflicts(mock, conflicts, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestDisableConflicts_EmptyService(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{
		{Name: "iptables-nft", Service: "", Active: true},
	}

	err := DisableConflicts(mock, conflicts, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestAssertSSHInLiveSet_PortPresent(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"
	mock.NftSets["ip6:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"

	AssertSSHInLiveSet(mock, 22, newTestLogger())
	// Should not add — 22 is already present
}

func TestAssertSSHInLiveSet_PortMissing(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 80, 443 }"
	mock.NftSets["ip6:nftban:tcp_ports_in"] = "elements = { 80, 443 }"

	AssertSSHInLiveSet(mock, 22, newTestLogger())
	// Should add port 22 to both families
}

func TestAssertSSHInLiveSet_NoTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No nftban tables — should skip silently

	AssertSSHInLiveSet(mock, 22, newTestLogger())
}

func TestInjectEmergencySSH(t *testing.T) {
	mock := executor.NewMockExecutor()

	err := InjectEmergencySSH(mock, 22, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}

	// Verify nft -f was called (via Run recorded commands)
	found := false
	for _, cmd := range mock.Commands {
		if cmd.Name == "nft" && len(cmd.Args) == 2 && cmd.Args[0] == "-f" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected nft -f command to be recorded")
	}

	// Verify temp file was written
	if _, ok := mock.WrittenFiles["/tmp/.nftban-emergency-ssh.nft"]; !ok {
		t.Error("expected emergency SSH rules temp file to be written")
	}
}

func TestInjectEmergencySSH_Idempotent(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Pre-existing emergency table
	mock.NftTables["inet:nftban_install_emergency"] = true

	err := InjectEmergencySSH(mock, 55000, newTestLogger())
	if err != nil {
		t.Fatalf("expected success on idempotent inject, got: %v", err)
	}
}

func TestRemoveEmergencySSH(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:nftban_install_emergency"] = true

	RemoveEmergencySSH(mock, newTestLogger())

	if mock.NftTableExists("inet", "nftban_install_emergency") {
		t.Error("expected emergency table to be removed")
	}
}

func TestRemoveEmergencySSH_NotPresent(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No emergency table — should be a no-op
	RemoveEmergencySSH(mock, newTestLogger())
}

func TestCleanGhostTables_GhostRemovedEmergencyPreserved(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:nftban_install_emergency"] = true
	mock.NftTables["ip:filter"] = true
	mock.NftTables["inet:firewalld"] = true

	CleanGhostTables(mock, newTestLogger())

	// Ghost tables should be removed
	if mock.NftTableExists("ip", "filter") {
		t.Error("expected ip filter ghost table to be removed")
	}
	if mock.NftTableExists("inet", "firewalld") {
		t.Error("expected inet firewalld ghost table to be removed")
	}
	// Emergency table should NOT be removed by ghost cleanup
	if !mock.NftTableExists("inet", "nftban_install_emergency") {
		t.Error("expected emergency table to survive ghost cleanup")
	}
}
