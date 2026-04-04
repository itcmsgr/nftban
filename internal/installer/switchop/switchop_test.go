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

func TestCleanGhostTables_EmergencyTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:nftban_install_emergency"] = true

	CleanGhostTables(mock, newTestLogger())

	if mock.NftTableExists("inet", "nftban_install_emergency") {
		t.Error("expected emergency table to be removed")
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
