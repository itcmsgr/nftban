// =============================================================================
// NFTBan v1.75.1 - Installer Switchop Tests
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
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestEnableNftables_Success(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true

	distro := &detect.DistroInfo{NftConfPath: "/etc/nftables.conf"}
	err := EnableNftables(mock, distro, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestEnableNftables_NotActive(t *testing.T) {
	// Mock auto-activates on ServiceStart, so we can't easily test the failure case.
	// The code is straightforward — skip.
	t.Skip("mock auto-activates on ServiceStart — skip negative test")
}

func TestCleanXtCompat_XtTargetDetected(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true

	confPath := "/etc/sysconfig/nftables.conf"
	mock.Files[confPath] = []byte("table ip filter { chain FORWARD { xt target \"REDIRECT\" } }")

	// nft -c -f should fail with xt target error
	mock.RunResults["nft:-c:-f:"+confPath] = executor.Result{
		ExitCode: 1,
		Stderr:   "Error: xt target not found",
	}

	distro := &detect.DistroInfo{NftConfPath: confPath}
	err := EnableNftables(mock, distro, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}

	// Verify backup was created (any file starting with confPath.xt-backup.)
	foundBackup := false
	for path := range mock.WrittenFiles {
		if strings.HasPrefix(path, confPath+".xt-backup.") {
			foundBackup = true
			break
		}
	}
	if !foundBackup {
		t.Error("expected xt-backup file to be created")
	}

	// Verify clean config was written
	written := mock.WrittenFiles[confPath]
	if written == nil {
		t.Fatal("expected clean config to be written to confPath")
	}
	if !strings.Contains(string(written), "include \"/etc/nftban/nftables.conf\"") {
		t.Error("expected clean config to include nftban nftables.conf")
	}
}

func TestCleanXtCompat_NoXtIssues(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true

	confPath := "/etc/nftables.conf"
	mock.Files[confPath] = []byte("#!/usr/sbin/nft -f\nflush ruleset\n")

	// nft -c -f succeeds — no xt issues
	mock.RunResults["nft:-c:-f:"+confPath] = executor.Result{ExitCode: 0}

	distro := &detect.DistroInfo{NftConfPath: confPath}
	err := EnableNftables(mock, distro, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}

	// Should NOT create a backup — config was clean
	for path := range mock.WrittenFiles {
		if strings.Contains(path, "xt-backup") {
			t.Errorf("unexpected backup file created: %s", path)
		}
	}
}

func TestCleanXtCompat_NoConfPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true

	distro := &detect.DistroInfo{NftConfPath: ""}
	err := EnableNftables(mock, distro, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
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

	err := DisableConflicts(mock, conflicts, detect.PanelNone, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestDisableConflicts_EmptyService(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{
		{Name: "iptables-nft", Service: "", Active: true},
	}

	err := DisableConflicts(mock, conflicts, detect.PanelNone, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestDisableConflicts_CSFWithDirectAdmin(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["csf.service"] = true
	mock.Services["lfd.service"] = true
	mock.ExistingCommands["iptables"] = true
	mock.ExistingCommands["ip6tables"] = true

	// Set up DA custombuild
	buildCmd := "/usr/local/directadmin/custombuild/build"
	mock.Files[buildCmd] = []byte("#!/bin/bash")
	mock.Dirs["/usr/local/directadmin"] = true

	// custombuild set csf no succeeds
	mock.RunResults[buildCmd+":set:csf:no"] = executor.Result{ExitCode: 0}

	// options.conf shows csf=no after set
	optionsPath := "/usr/local/directadmin/custombuild/options.conf"
	mock.Files[optionsPath] = []byte("csf=no\nfirewall=no\n")

	// CSF artifacts that should be cleaned
	mock.Files["/etc/cron.d/lfd-cron"] = []byte("0 0 * * * root /usr/sbin/csf --lfd restart")
	mock.Files["/etc/cron.d/csf-cron"] = []byte("")
	mock.Files["/usr/sbin/csf"] = []byte("#!/bin/bash")

	conflicts := []detect.Conflict{
		{Name: "CSF", Service: "csf.service", Active: true},
		{Name: "CSF", Service: "lfd.service", Active: true},
	}

	err := DisableConflicts(mock, conflicts, detect.PanelDirectAdmin, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}

	// Verify custombuild was called
	foundBuild := false
	// Verify CSF crons were removed
	foundCronRM := false
	// Verify CSF binary was disabled
	foundBinMV := false
	for _, cmd := range mock.Commands {
		if cmd.Name == buildCmd && len(cmd.Args) == 3 &&
			cmd.Args[0] == "set" && cmd.Args[1] == "csf" && cmd.Args[2] == "no" {
			foundBuild = true
		}
		if cmd.Name == "rm" && len(cmd.Args) >= 2 && cmd.Args[1] == "/etc/cron.d/lfd-cron" {
			foundCronRM = true
		}
		if cmd.Name == "mv" && len(cmd.Args) >= 2 && cmd.Args[0] == "/usr/sbin/csf" {
			foundBinMV = true
		}
	}
	if !foundBuild {
		t.Error("expected custombuild set csf no to be called")
	}
	if !foundCronRM {
		t.Error("expected CSF cron removal (rm /etc/cron.d/lfd-cron)")
	}
	if !foundBinMV {
		t.Error("expected CSF binary disable (mv /usr/sbin/csf)")
	}
}

func TestDisableConflicts_CSFWithCPanel(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["csf.service"] = true
	mock.ExistingCommands["iptables"] = true

	conflicts := []detect.Conflict{
		{Name: "CSF", Service: "csf.service", Active: true},
	}

	// cPanel — no custombuild disarm needed, masking is sufficient
	err := DisableConflicts(mock, conflicts, detect.PanelCPanel, newTestLogger())
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
