// =============================================================================
// NFTBan v1.73 - Installer Conflict Detection Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-conflicts-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for conflicting firewall detection"
// meta:inventory.files="internal/installer/detect/conflicts_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestDetectConflicts_NoConflicts(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{ExitCode: 0, Stdout: "table ip nftban\ntable ip6 nftban\n"}

	conflicts := DetectConflicts(mock, newTestLogger())
	if len(conflicts) != 0 {
		t.Errorf("expected 0 conflicts, got %d: %v", len(conflicts), ConflictNames(conflicts))
	}
}

func TestDetectConflicts_CSF(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["csf.service"] = true
	mock.Services["lfd.service"] = true
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{ExitCode: 0, Stdout: ""}

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	if len(names) != 1 || names[0] != "CSF" {
		t.Errorf("expected [CSF], got %v", names)
	}
}

func TestDetectConflicts_Firewalld(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["firewalld.service"] = true
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{ExitCode: 0, Stdout: ""}

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	if len(names) != 1 || names[0] != "firewalld" {
		t.Errorf("expected [firewalld], got %v", names)
	}
}

func TestDetectConflicts_GhostTables(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable ip6 nftban\ntable ip filter\ntable ip nat\n",
	}

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	if len(names) != 1 || names[0] != "iptables-nft" {
		t.Errorf("expected [iptables-nft] for ghost filter+nat, got %v", names)
	}
}

func TestDetectConflicts_FirewalldGhostTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable inet firewalld\n",
	}

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	if len(names) != 1 || names[0] != "firewalld" {
		t.Errorf("expected [firewalld] for ghost firewalld table, got %v", names)
	}
}

func TestDetectConflicts_Multiple(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["ufw.service"] = true
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable ip filter\n",
	}

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	if len(names) != 2 {
		t.Errorf("expected 2 conflicts (UFW + iptables-nft), got %d: %v", len(names), names)
	}
}

func TestDetectConflicts_NoNft(t *testing.T) {
	// nft not installed — only check services
	mock := executor.NewMockExecutor()
	mock.Services["iptables.service"] = true

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	if len(names) != 1 || names[0] != "iptables" {
		t.Errorf("expected [iptables], got %v", names)
	}
}

func TestDetectConflicts_NftbanTablesIgnored(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	// All NFTBan-owned tables — should produce no conflicts
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable ip6 nftban\ntable ip raw\ntable ip6 raw\ntable inet nftban_install_emergency\n",
	}

	conflicts := DetectConflicts(mock, newTestLogger())
	if len(conflicts) != 0 {
		t.Errorf("expected 0 conflicts for NFTBan-owned tables, got %d", len(conflicts))
	}
}
