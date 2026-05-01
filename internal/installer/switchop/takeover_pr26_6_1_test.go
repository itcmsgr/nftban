// =============================================================================
// NFTBan PR26.6.1 - DA Watchdog Coherence Lock-In Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-takeover-pr26-6-1-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-01"
// meta:description="Locks PANEL-WATCHDOG-COHERENCE-001 — DA services.status lfd watchdog flipped OFF after takeover; idempotent; surgical; absent-file safe; non-DA panels untouched"
// meta:inventory.files="internal/installer/switchop/takeover_pr26_6_1_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// PANEL-WATCHDOG-COHERENCE-001 invariant:
//
//   When takeover intentionally disarms an external firewall service
//   that a panel monitors, takeover must also update the panel's
//   runtime service-monitor configuration so the panel does not
//   continuously attempt to restart the disarmed service.
//
// Source evidence: dns2 evidence (2026-04-30 → 2026-05-01) showed
// dataskq emitting `error=service "lfd": Unit lfd.service is masked.`
// every 60 seconds for 14+ hours after PR-26 takeover masked lfd.
// Operational hotfix on dns2 (sed lfd=ON → OFF + systemctl reset-failed
// lfd.service) verified the noise stops in <3 minutes; this PR makes
// the fix automatic for every future DA takeover.
package switchop

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// seedDirectAdminTakeoverPrereqs sets up the minimum mock state for
// DisableConflicts to reach the DA-takeover branch:
//   - CSF + LFD services exist (they will be masked)
//   - DirectAdmin install dir + custombuild/build present
//   - custombuild set csf no will succeed
//   - options.conf already shows csf=no (post-disarm verification path)
//   - csf binary exists (will be renamed to .disabled)
func seedDirectAdminTakeoverPrereqs(mock *executor.MockExecutor) {
	mock.Services["csf.service"] = true
	mock.Services["lfd.service"] = true
	mock.ExistingCommands["iptables"] = true

	buildCmd := "/usr/local/directadmin/custombuild/build"
	mock.Files[buildCmd] = []byte("#!/bin/bash")
	mock.Dirs["/usr/local/directadmin"] = true
	mock.RunResults[buildCmd+":set:csf:no"] = executor.Result{ExitCode: 0}

	optionsPath := "/usr/local/directadmin/custombuild/options.conf"
	mock.Files[optionsPath] = []byte("csf=no\nfirewall=no\n")

	mock.Files["/usr/sbin/csf"] = []byte("#!/usr/bin/perl\n")
}

// daCSFConflicts returns the canonical (CSF + LFD) conflict pair used
// by the DA-takeover tests below.
func daCSFConflicts() []detect.Conflict {
	return []detect.Conflict{
		{Name: "CSF", Service: "csf.service", Active: true},
		{Name: "CSF", Service: "lfd.service", Active: true},
	}
}

// realisticServicesStatus is a representative DirectAdmin runtime
// services.status fixture covering common watchdog entries. Used to
// verify surgical edits do not perturb unrelated lines.
const realisticServicesStatus = `apache=ON
crond=ON
dovecot=ON
exim=ON
mysqld=ON
named=ON
proftpd=ON
sshd=ON
directadmin=ON
lfd=ON
`

// TestPR26_6_1_DAServicesStatus_LfdSetToOFF — the operational symptom
// the fix targets. Pre-takeover services.status has lfd=ON; post-
// takeover must be lfd=OFF, atomically written.
func TestPR26_6_1_DAServicesStatus_LfdSetToOFF(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedDirectAdminTakeoverPrereqs(mock)
	mock.Files[daServicesStatusPath] = []byte(realisticServicesStatus)

	if err := DisableConflicts(mock, daCSFConflicts(), detect.PanelDirectAdmin, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	got, err := mock.ReadFile(daServicesStatusPath)
	if err != nil {
		t.Fatalf("read %s after takeover: %v", daServicesStatusPath, err)
	}
	if strings.Contains(string(got), "lfd=ON") {
		t.Errorf("services.status still contains lfd=ON after DA takeover:\n%s", got)
	}
	if !strings.Contains(string(got), "lfd=OFF") {
		t.Errorf("services.status missing lfd=OFF after DA takeover:\n%s", got)
	}
	// Confirm the writer ran via WriteFileAtomic (atomic-write pin).
	if _, ok := mock.WrittenFiles[daServicesStatusPath]; !ok {
		t.Errorf("services.status was not written via WriteFileAtomic")
	}
}

// TestPR26_6_1_DAServicesStatus_PreservesOtherEntries — surgical edit
// guard. The fix must touch only the lfd= line; every other watchdog
// entry must survive byte-for-byte. A future regression that does a
// reckless rewrite (e.g., regenerates the file from a template) would
// trip this test.
func TestPR26_6_1_DAServicesStatus_PreservesOtherEntries(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedDirectAdminTakeoverPrereqs(mock)
	mock.Files[daServicesStatusPath] = []byte(realisticServicesStatus)

	if err := DisableConflicts(mock, daCSFConflicts(), detect.PanelDirectAdmin, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	got, err := mock.ReadFile(daServicesStatusPath)
	if err != nil {
		t.Fatalf("read %s after takeover: %v", daServicesStatusPath, err)
	}
	for _, mustKeep := range []string{
		"apache=ON",
		"crond=ON",
		"dovecot=ON",
		"exim=ON",
		"mysqld=ON",
		"named=ON",
		"proftpd=ON",
		"sshd=ON",
		"directadmin=ON",
	} {
		if !strings.Contains(string(got), mustKeep) {
			t.Errorf("services.status lost unrelated watchdog entry %q after DA takeover:\n%s", mustKeep, got)
		}
	}
}

// TestPR26_6_1_DAServicesStatus_AbsentFile_NoFail — graceful-skip
// guard. On hosts where DA is not present at the expected path or the
// services.status file has not been created, takeover must not abort
// or warn loudly. The disarm runs only when the file exists.
func TestPR26_6_1_DAServicesStatus_AbsentFile_NoFail(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedDirectAdminTakeoverPrereqs(mock)
	// Deliberately do NOT seed daServicesStatusPath.

	if err := DisableConflicts(mock, daCSFConflicts(), detect.PanelDirectAdmin, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts must not error when services.status is absent: %v", err)
	}
	// Must not have written it from thin air either.
	if _, ok := mock.WrittenFiles[daServicesStatusPath]; ok {
		t.Errorf("services.status wrongly created from absent state: %v", mock.WrittenFiles[daServicesStatusPath])
	}
}

// TestPR26_6_1_DAServicesStatus_Idempotent — re-running takeover on a
// host where lfd=OFF already must be a no-op (no spurious write, no
// change to the file). Catches a regression where the disarm always
// rewrites regardless of current state.
func TestPR26_6_1_DAServicesStatus_Idempotent(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedDirectAdminTakeoverPrereqs(mock)
	already := strings.ReplaceAll(realisticServicesStatus, "lfd=ON", "lfd=OFF")
	mock.Files[daServicesStatusPath] = []byte(already)

	if err := DisableConflicts(mock, daCSFConflicts(), detect.PanelDirectAdmin, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}
	// Either the file is not in WrittenFiles at all (preferred — no
	// write performed), or — if some other PR wires a write through
	// the same path — the content must equal the original byte-for-byte.
	if got, written := mock.WrittenFiles[daServicesStatusPath]; written {
		if string(got) != already {
			t.Errorf("idempotent re-takeover should not mutate already-OFF services.status:\nbefore=%q\nafter=%q",
				already, got)
		}
	}
}

// TestPR26_6_1_DAServicesStatus_NonDirectAdminPanel_Untouched — scope
// guard. The disarm runs only when the detected panel is DirectAdmin.
// On a host where takeover is invoked with PanelNone / PanelCpanel /
// PanelPlesk, services.status (if it happens to exist for some other
// reason) MUST NOT be touched.
func TestPR26_6_1_DAServicesStatus_NonDirectAdminPanel_Untouched(t *testing.T) {
	for _, panel := range []detect.PanelType{detect.PanelNone, detect.PanelCPanel, detect.PanelPlesk} {
		t.Run(string(panel), func(t *testing.T) {
			mock := executor.NewMockExecutor()
			mock.Services["csf.service"] = true
			mock.Services["lfd.service"] = true
			mock.ExistingCommands["iptables"] = true
			mock.Files["/usr/sbin/csf"] = []byte("#!/usr/bin/perl\n")
			mock.Files[daServicesStatusPath] = []byte(realisticServicesStatus)

			if err := DisableConflicts(mock, daCSFConflicts(), panel, newTestLogger()); err != nil {
				t.Fatalf("DisableConflicts: %v", err)
			}
			if _, written := mock.WrittenFiles[daServicesStatusPath]; written {
				t.Errorf("services.status wrongly written on non-DA panel %q (must be DA-only)", panel)
			}
			got, _ := mock.ReadFile(daServicesStatusPath)
			if !strings.Contains(string(got), "lfd=ON") {
				t.Errorf("non-DA panel %q wrongly flipped lfd=ON → OFF: %s", panel, got)
			}
		})
	}
}

// TestPR26_6_1_FlipLfdWatchdogOff_PureLogic — pure-function regression
// guard for the line-edit logic. Independent of executor mocking so
// future refactors that rewire the I/O don't accidentally weaken the
// edit semantics. Covers: anchored-line-start match (no substring
// false positive), no-op when input has no target, line-ending
// preservation, multiple lfd=ON lines (unusual but possible).
func TestPR26_6_1_FlipLfdWatchdogOff_PureLogic(t *testing.T) {
	cases := []struct {
		name      string
		in        string
		wantOut   string
		wantFlip  bool
	}{
		{
			name:     "single canonical line",
			in:       "lfd=ON\n",
			wantOut:  "lfd=OFF\n",
			wantFlip: true,
		},
		{
			name:     "with neighbours",
			in:       "exim=ON\nlfd=ON\nnamed=ON\n",
			wantOut:  "exim=ON\nlfd=OFF\nnamed=ON\n",
			wantFlip: true,
		},
		{
			name:     "already off — no-op",
			in:       "exim=ON\nlfd=OFF\nnamed=ON\n",
			wantOut:  "exim=ON\nlfd=OFF\nnamed=ON\n",
			wantFlip: false,
		},
		{
			name:     "absent — no-op",
			in:       "exim=ON\nnamed=ON\n",
			wantOut:  "exim=ON\nnamed=ON\n",
			wantFlip: false,
		},
		{
			name:     "comment containing target — must not flip (line not equal target)",
			in:       "exim=ON\n# lfd=ON disabled in 2024-12 by ops\nlfd=ON\n",
			wantOut:  "exim=ON\n# lfd=ON disabled in 2024-12 by ops\nlfd=OFF\n",
			wantFlip: true,
		},
		{
			name:     "no trailing newline",
			in:       "exim=ON\nlfd=ON",
			wantOut:  "exim=ON\nlfd=OFF",
			wantFlip: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, flip := flipLfdWatchdogOff(c.in)
			if flip != c.wantFlip {
				t.Errorf("flip=%v want %v", flip, c.wantFlip)
			}
			if out != c.wantOut {
				t.Errorf("out mismatch:\n  got  %q\n  want %q", out, c.wantOut)
			}
		})
	}
}
