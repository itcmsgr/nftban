// =============================================================================
// NFTBan v1.73 - Installer Authority Classification Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-authority-classify-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for authority decision tree"
// meta:inventory.files="internal/installer/authority/classify_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package authority

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

// authoritativeMock returns a MockExecutor pre-wired with table+chain+daemon
// all present. PR-22B tightened IsNftbanAuthoritative to require all three.
func authoritativeMock() *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.NftTables["ip:nftban"] = true
	m.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	m.Services[NftbanDaemonUnit] = true
	return m
}

func TestClassify_Update(t *testing.T) {
	decision := Classify(authoritativeMock(), nil, detect.PanelNone, false, false, newTestLogger())
	if decision != Update {
		t.Errorf("decision = %s, want UPDATE", decision)
	}
}

func TestClassify_Update_WithConflicts(t *testing.T) {
	// UPDATE takes priority even if conflicts exist
	mock := authoritativeMock()
	conflicts := []detect.Conflict{{Name: "firewalld", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, false, false, newTestLogger())
	if decision != Update {
		t.Errorf("decision = %s, want UPDATE (table+chain+daemon exist, ignoring conflicts)", decision)
	}
}

func TestClassify_Fresh(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No NFTBan table, no daemon, no conflicts
	decision := Classify(mock, nil, detect.PanelNone, false, false, newTestLogger())
	if decision != Fresh {
		t.Errorf("decision = %s, want FRESH", decision)
	}
}

func TestClassify_Takeover_EnvVar(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Env["NFTBAN_TAKEOVER"] = "1"

	conflicts := []detect.Conflict{{Name: "CSF", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, false, false, newTestLogger())
	if decision != Takeover {
		t.Errorf("decision = %s, want TAKEOVER (env var)", decision)
	}
}

func TestClassify_Takeover_Flag(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{{Name: "UFW", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, true, false, newTestLogger())
	if decision != Takeover {
		t.Errorf("decision = %s, want TAKEOVER (--takeover flag)", decision)
	}
}

// PR-22B: panel detection ALONE no longer auto-approves takeover.
// Operators must pass --panel-auto-takeover explicitly.
func TestClassify_PanelDetected_NoFlag_Aborts(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{{Name: "firewalld", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelCPanel, false, false /* panelAutoApprove */, newTestLogger())
	if decision != Abort {
		t.Errorf("decision = %s, want ABORT — panel alone must not grant takeover (PR-22B audit fix)", decision)
	}
}

// PR-22B: panel auto-approve works ONLY when the explicit flag is set.
func TestClassify_PanelDetected_WithFlag_Takesover(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{{Name: "firewalld", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelCPanel, false, true /* panelAutoApprove */, newTestLogger())
	if decision != Takeover {
		t.Errorf("decision = %s, want TAKEOVER (panel + explicit --panel-auto-takeover)", decision)
	}
}

func TestClassify_Abort(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{{Name: "CSF", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, false, false, newTestLogger())
	if decision != Abort {
		t.Errorf("decision = %s, want ABORT (conflicts, no approval)", decision)
	}
}

// PR-22B: orphan ip nftban table WITHOUT active daemon (crashed prior
// install) must NOT classify as Update. It used to slip through the
// legacy predicate and cause phaseSwitch to skip emergency SSH injection.
// The new predicate routes this case to Ambiguous.
func TestClassify_Ambiguous_OrphanTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	// Daemon NOT active.

	decision := Classify(mock, nil, detect.PanelNone, false, false, newTestLogger())
	if decision != Ambiguous {
		t.Errorf("decision = %s, want AMBIGUOUS (orphan table without active daemon) — PR-22B audit fix", decision)
	}
}

// PR-22B: daemon-up without the ip nftban table also triggers Ambiguous.
// Symmetric case to the orphan-table one.
func TestClassify_Ambiguous_DaemonWithoutTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services[NftbanDaemonUnit] = true
	// No table.

	decision := Classify(mock, nil, detect.PanelNone, false, false, newTestLogger())
	if decision != Ambiguous {
		t.Errorf("decision = %s, want AMBIGUOUS (daemon active without kernel table)", decision)
	}
}

// Table without chain → not authoritative, but no daemon either; table
// presence alone is still an orphan artifact → Ambiguous (PR-22B). Prior
// behaviour was Fresh, which hid the orphan from the operator.
func TestClassify_Ambiguous_TableWithoutChain(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 1, Stderr: "no such chain"}

	decision := Classify(mock, nil, detect.PanelNone, false, false, newTestLogger())
	if decision != Ambiguous {
		t.Errorf("decision = %s, want AMBIGUOUS (table without chain is orphan) — PR-22B audit fix", decision)
	}
}

// v1.235 (owner 2026-10-10): a leftover NFTBan table is not consent to take over an active
// firewall. Measured on f2-p8-u2604: orphan `table ip nftban` + active unapproved UFW was
// AMBIGUOUS and COMMITTED the NFTBan ruleset next to UFW. Conflicts are decided first.
func TestClassify_OrphanArtifactsDoNotOverrideUnapprovedConflict(t *testing.T) {
	for name, setup := range map[string]func(m *executor.MockExecutor){
		"orphan table":         func(m *executor.MockExecutor) { m.NftTables["ip:nftban"] = true },
		"daemon without table": func(m *executor.MockExecutor) { m.Services[NftbanDaemonUnit] = true },
	} {
		mock := executor.NewMockExecutor()
		setup(mock)
		conflicts := []detect.Conflict{{Name: "UFW", Active: true}}
		if d := Classify(mock, conflicts, detect.PanelNone, false, false, newTestLogger()); d != Abort {
			t.Errorf("%s + unapproved UFW: decision = %s, want ABORT", name, d)
		}
		if d := Classify(mock, conflicts, detect.PanelNone, true, false, newTestLogger()); d != Takeover {
			t.Errorf("%s + UFW + --takeover: decision = %s, want TAKEOVER (the path that disables the conflict)", name, d)
		}
		// The repair of a previously authorized installation (f2-p8-u2604: upgrade interrupted
		// after a takeover; UFW's iptables-nft tables still loaded) proceeds; approval still wins.
		if d := ClassifyWithPriorGrant(mock, conflicts, detect.PanelNone, false, false, true, newTestLogger()); d != Ambiguous {
			t.Errorf("%s + conflict + prior grant: decision = %s, want AMBIGUOUS (repair)", name, d)
		}
		if d := ClassifyWithPriorGrant(mock, conflicts, detect.PanelNone, true, false, true, newTestLogger()); d != Takeover {
			t.Errorf("%s + conflict + prior grant + --takeover: decision = %s, want TAKEOVER", name, d)
		}
	}
	// No orphan artifact: a prior grant alone never bypasses the refusal.
	if d := ClassifyWithPriorGrant(executor.NewMockExecutor(), []detect.Conflict{{Name: "UFW", Active: true}},
		detect.PanelNone, false, false, true, newTestLogger()); d != Abort {
		t.Errorf("conflict + prior grant, no artifact: decision = %s, want ABORT", d)
	}
}

// CONTRACT CHANGED 2026-08-11 (CSF-CLOSE-4). This previously asserted
// "UPDATE wins ... (overrides everything)" even with forceApprove=true.
// Runtime proof (el9-clean, R3-P1 #3) showed that rule left NFTBan and CSF
// BOTH effective — 65 nftban rules alongside 129 CSF rules — with
// DisableConflicts never entered, rc=0 and status=PROTECTED. Explicit
// operator approval was being discarded by the decision layer.
//
//	NFTBAN OWNING THE FIREWALL != NOTHING ELSE DOES
//
// The safety property worth keeping is narrower and is asserted below:
// UPDATE still wins when takeover was NOT explicitly approved, so routine
// upgrades on a host that merely has another firewall installed never turn
// destructive.
func TestClassify_Priority_ExplicitApprovalContestsUpdate(t *testing.T) {
	mock := authoritativeMock()
	conflicts := []detect.Conflict{
		{Name: "CSF", Active: true},
		{Name: "UFW", Active: true},
		{Name: "firewalld", Active: true},
	}

	// Explicitly approved takeover MUST contest, not silently update.
	if d := Classify(mock, conflicts, detect.PanelCPanel, true, true, newTestLogger()); d != Takeover {
		t.Errorf("explicit approval with active conflicts = %s, want TAKEOVER", d)
	}

	// NEGATIVE CONTROL: without explicit approval the old priority holds.
	if d := Classify(mock, conflicts, detect.PanelCPanel, false, false, newTestLogger()); d != Update {
		t.Errorf("unapproved run with conflicts = %s, want UPDATE (upgrades stay safe)", d)
	}
}

// PR-22B regression guard: IsNftbanAuthoritative must require ALL THREE
// (table + chain + daemon). Drop any one and the predicate must return
// false.
func TestIsNftbanAuthoritative_RequiresAllThree(t *testing.T) {
	// Baseline — all three present.
	if !IsNftbanAuthoritative(authoritativeMock()) {
		t.Fatal("baseline authoritativeMock must satisfy the predicate")
	}

	// Drop table.
	m1 := authoritativeMock()
	m1.NftTables["ip:nftban"] = false
	if IsNftbanAuthoritative(m1) {
		t.Error("predicate must return false when table is missing")
	}

	// Drop chain (exit code non-zero).
	m2 := authoritativeMock()
	m2.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 1}
	if IsNftbanAuthoritative(m2) {
		t.Error("predicate must return false when chain probe fails")
	}

	// Drop daemon.
	m3 := authoritativeMock()
	m3.Services[NftbanDaemonUnit] = false
	if IsNftbanAuthoritative(m3) {
		t.Error("predicate must return false when daemon is inactive (PR-22B tightening)")
	}
}
