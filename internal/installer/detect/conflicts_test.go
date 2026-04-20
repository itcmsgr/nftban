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

// TestDetectConflicts_GhostTablesOnly — PR-P2-2A: a host with ONLY
// `ip filter` / `ip nat` / `ip mangle` ghost nft tables and NO
// corroborating iptables signal (no service, no live rules) is NOT
// a conflict. Stock Ubuntu nftables ships a benign baseline `inet
// filter` that was false-positiving as an iptables conflict before
// this fix, causing Abort/Takeover decisions on every clean Ubuntu
// host with nftban.
func TestDetectConflicts_GhostTablesOnly_NotConflict(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable ip6 nftban\ntable ip filter\ntable ip nat\n",
	}
	// Explicitly: no iptables.service, no iptables-save rules.

	conflicts := DetectConflicts(mock, newTestLogger())
	for _, c := range conflicts {
		if c.Name == "iptables-nft" || c.Name == "iptables" {
			t.Errorf("ghost-table-only iptables must NOT be a conflict (PR-P2-2A); got %+v", c)
		}
	}
}

// TestDetectConflicts_GhostPlusService_IsConflict — inverse of the
// regression guard: a ghost table corroborated by iptables.service
// IS a legitimate conflict.
func TestDetectConflicts_GhostPlusService_IsConflict(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.Services["iptables.service"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable ip filter\n",
	}

	conflicts := DetectConflicts(mock, newTestLogger())
	var sawIptables bool
	for _, c := range conflicts {
		if c.Name == "iptables" || c.Name == "iptables-nft" {
			sawIptables = true
		}
	}
	if !sawIptables {
		t.Errorf("expected iptables conflict when ghost table + service both present; got %+v", conflicts)
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

// TestDetectConflicts_Multiple — PR-P2-2A: a host with real UFW AND
// a ghost `ip filter` table (no iptables corroboration) yields just
// one conflict (UFW). The ghost table alone no longer counts per the
// corroboration rule.
func TestDetectConflicts_UFWPlusUnqualifiedGhost_OneConflict(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["ufw.service"] = true
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable ip filter\n",
	}

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	// UFW must be counted; iptables/iptables-nft must NOT be (ghost-alone).
	var sawUFW, sawIptables bool
	for _, n := range names {
		if n == "UFW" {
			sawUFW = true
		}
		if n == "iptables" || n == "iptables-nft" {
			sawIptables = true
		}
	}
	if !sawUFW {
		t.Errorf("expected UFW in conflicts; got %v", names)
	}
	if sawIptables {
		t.Errorf("ghost-table-only iptables must NOT be a conflict; got %v", names)
	}
}

// TestDetectConflicts_Multiple_WithIptablesService — ghost `ip filter`
// + iptables.service active + UFW → both conflicts counted.
func TestDetectConflicts_Multiple_WithIptablesService(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["ufw.service"] = true
	mock.Services["iptables.service"] = true
	mock.ExistingCommands["nft"] = true
	mock.RunResults["nft:list:tables"] = executor.Result{
		ExitCode: 0,
		Stdout: "table ip nftban\ntable ip filter\n",
	}

	conflicts := DetectConflicts(mock, newTestLogger())
	names := ConflictNames(conflicts)
	var sawUFW, sawIptables bool
	for _, n := range names {
		if n == "UFW" {
			sawUFW = true
		}
		if n == "iptables" || n == "iptables-nft" {
			sawIptables = true
		}
	}
	if !sawUFW || !sawIptables {
		t.Errorf("expected UFW + iptables (service corroborates ghost); got %v", names)
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
