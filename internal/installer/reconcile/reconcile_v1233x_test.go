// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
package reconcile

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

const genPath = "/run/nftban/convergence-generation"

// healthyRuleset: v1.233.0 shape — keyed per-source, family-correlated, zero bare.
const healthyRuleset = `table ip nftban {
	set connlimit_ssh_v4 {
		type ipv4_addr
		size 65535
		flags dynamic
		elements = { 203.0.113.44 ct count over 15 }
	}
	chain input {
		type filter hook input priority filter; policy drop;
		tcp dport @ssh_ports add @connlimit_ssh_v4 { ip saddr ct count over 15 } drop # handle 6
		tcp dport @ssh_ports add @connlimit_ssh_v6 { ip6 saddr ct count over 15 } drop # handle 7
		tcp dport 80 add @connlimit_http_v4 { ip saddr ct count over 200 } drop # handle 8
		tcp dport 80 add @connlimit_http_v6 { ip6 saddr ct count over 200 } drop # handle 9
	}
}
`

// ⛔ MUTATING COMMANDS. If reconciliation ever runs one of these, the lane's central
// promise is broken regardless of what any field claims.
var mutatingCommands = []string{
	"nftban", "nftban-installer", "rpm", "dnf", "yum", "apt", "apt-get", "dpkg",
}
var mutatingArgs = []string{
	"rebuild", "reload", "reset", "restart", "install", "repair", "--force",
	"add", "flush", "delete", "insert", "replace", "-f",
}

// writeFixtureState lays down a REBUILD_REFUSED_BUSY record shaped like production srv3.
func writeFixtureState(t *testing.T, dir string, st state.InstallState, version string) *state.StateFile {
	t.Helper()
	sf := state.NewStateFile(dir)
	sf.State = st
	sf.Mode = "upgrade"
	sf.Version = version
	sf.Timestamp = time.Date(2026, 9, 23, 9, 49, 1, 0, time.UTC)
	sf.RebuildExitCode = 1
	sf.RebuildDurationMs = 30404
	sf.FailureReason = "rebuild REFUSED_BUSY: every attempt within the installer deadline was refused " +
		"by the convergence lock; no rebuild executed, the firewall was not modified"
	sf.WhitelistConvergence = "CONVERGED"
	if err := sf.WriteAtomic(); err != nil {
		t.Fatalf("fixture state write: %v", err)
	}
	return sf
}

type harness struct {
	in     Inputs
	mock   *executor.MockExecutor
	stPath string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dir := t.TempDir()
	writeFixtureState(t, dir, state.StateRebuildRefusedBusy, "1.233.0")

	m := executor.NewMockExecutor()
	m.Files[fhs.VersionFile] = []byte("1.233.0")
	m.Files[genPath] = []byte("40\n")
	m.Files["/proc/sys/kernel/random/boot_id"] = []byte("8f3a2c11-dead-beef-0000-1234567890ab\n")
	m.RunResults["systemctl:is-active:nftband.service"] = executor.Result{ExitCode: 0, Stdout: "active\n"}
	m.RunResults["nft:-a:list:ruleset"] = executor.Result{ExitCode: 0, Stdout: healthyRuleset}

	// The convergence lock is always grantable unless a case replaces this.
	acquireConvergence = func(time.Duration) (func(), error) { return func() {}, nil }

	return &harness{
		mock:   m,
		stPath: filepath.Join(dir, state.StateFileName),
		in: Inputs{
			Exec:           m,
			StateDir:       dir,
			RunID:          "TEST-RUN",
			GenerationPath: genPath,
			ForensicPath:   filepath.Join(dir, "reconcile.jsonl"),
		},
	}
}

func sha256File(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p) // #nosec G304 — test temp dir
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// assertNoRuntimeMutation is the invariant every case shares.
func assertNoRuntimeMutation(t *testing.T, h *harness) {
	t.Helper()
	for _, c := range h.mock.Commands {
		for _, bad := range mutatingCommands {
			if c.Name == bad {
				t.Errorf("RUNTIME MUTATED: reconciliation invoked %q %v — it must prove, never repair",
					c.Name, c.Args)
			}
		}
		if c.Name == "nft" {
			for _, a := range c.Args {
				for _, bad := range mutatingArgs {
					if a == bad {
						t.Errorf("RUNTIME MUTATED: nft invoked with %q (%v)", a, c.Args)
					}
				}
			}
		}
	}
}

// ═════════════════════════════════════════════════════════════════════════════
// P1 — the positive case
// ═════════════════════════════════════════════════════════════════════════════
func TestP1_ProvenLiveRealityReconcilesTheRecord(t *testing.T) {
	h := newHarness(t)
	before := sha256File(t, h.stPath)

	out, err := Run(h.in)
	if err != nil {
		t.Fatalf("Run errored: %v", err)
	}
	if !out.Reconciled {
		t.Fatalf("P1 REFUSED on a fully proven host: %s\nassertions: %+v", out.Refusal, out.Event.Assertions)
	}
	assertNoRuntimeMutation(t, h)

	sf := state.NewStateFile(h.in.StateDir)
	if rerr := sf.Read(); rerr != nil {
		t.Fatalf("re-read: %v", rerr)
	}
	if sf.State != state.StateCommitted {
		t.Errorf("INSTALL_STATE = %s, want COMMITTED", sf.State)
	}
	if sf.ConvergenceVerified != state.ConvergenceVerifiedValue {
		t.Errorf("CONVERGENCE_VERIFIED = %q, want VERIFIED", sf.ConvergenceVerified)
	}
	if sf.ConvergenceStructureSchema == "" || sf.ConvergenceStructureFingerprint == "" {
		t.Errorf("structure attribution missing: schema=%q fingerprint=%q — a durable record with no "+
			"structure identity cannot say WHAT it certified",
			sf.ConvergenceStructureSchema, sf.ConvergenceStructureFingerprint)
	}
	if !strings.HasPrefix(sf.ConvergenceStructureFingerprint, "sha256:") {
		t.Errorf("fingerprint %q is not self-describing", sf.ConvergenceStructureFingerprint)
	}
	if after := sha256File(t, h.stPath); after == before {
		t.Error("P1 changed nothing — the positive case must actually move the record, or every " +
			"negative case below is vacuous")
	}

	// ⛔ THE ORIGINAL FAILURE MUST SURVIVE. Transition clears FAILURE_REASON on
	// COMMITTED, so the forensic event is the only place it can live.
	if out.Event.OriginalFailureReason == "" || out.Event.OriginalRebuildExitCode != 1 {
		t.Error("reconciliation ERASED the history it reconciled: the original failure reason / " +
			"rebuild exit code is absent from the forensic event")
	}
	if out.Event.PreviousState != string(state.StateRebuildRefusedBusy) {
		t.Errorf("forensic previous_state = %q", out.Event.PreviousState)
	}
	if out.Event.RuntimeMutated {
		t.Error("forensic event claims runtime_mutated=true")
	}
	if out.Event.ObservedBootID == "" {
		t.Error("the non-authoritative generation was recorded without a boot id — after a reboot a " +
			"reader could not tell the counter had reset")
	}
	if out.Event.ObservedGenerationPre != 40 || out.Event.ObservedGenerationPst != 40 {
		t.Errorf("generation forensics = %d/%d, want 40/40",
			out.Event.ObservedGenerationPre, out.Event.ObservedGenerationPst)
	}

	// The forensic log must actually exist on disk.
	if b, ferr := os.ReadFile(h.in.ForensicPath); ferr != nil || !strings.Contains(string(b), "RECONCILED") {
		t.Errorf("forensic log missing or incomplete: err=%v", ferr)
	}
}

// TestP1_DryRunProvesWithoutPersisting — the mode every negative case relies on.
func TestP1_DryRunProvesWithoutPersisting(t *testing.T) {
	h := newHarness(t)
	h.in.DryRun = true
	before := sha256File(t, h.stPath)

	out, err := Run(h.in)
	if err != nil {
		t.Fatalf("Run errored: %v", err)
	}
	if out.Reconciled {
		t.Error("dry run reported Reconciled=true")
	}
	if out.Event.Outcome != "DRY_RUN_WOULD_RECONCILE" {
		t.Errorf("outcome = %q, want DRY_RUN_WOULD_RECONCILE (every assertion passed)", out.Event.Outcome)
	}
	if after := sha256File(t, h.stPath); after != before {
		t.Error("DRY RUN MUTATED THE RECORD")
	}
	assertNoRuntimeMutation(t, h)
}

// ═════════════════════════════════════════════════════════════════════════════
// N1–N11 — the falsification matrix
// ═════════════════════════════════════════════════════════════════════════════
// Every case must satisfy ALL of:
//
//	state_before_sha256 == state_after_sha256
//	runtime unchanged · no rebuild · no reinstall
//	the refusal NAMES the actual defect
func TestNegativeMatrix_RefusesAndChangesNothing(t *testing.T) {
	cases := []struct {
		id, name    string
		setup       func(*harness)
		wantRefusal string
	}{
		{
			id: "N1", name: "ineligible state: DEGRADED",
			setup: func(h *harness) {
				writeFixtureState(t, h.in.StateDir, state.StateDegraded, "1.233.0")
			},
			wantRefusal: "not reconcile-eligible",
		},
		{
			id: "N2", name: "ineligible state: APPLIED_UNVERIFIED (a mutation DID land)",
			setup: func(h *harness) {
				writeFixtureState(t, h.in.StateDir, state.StateAppliedUnverified, "1.233.0")
			},
			wantRefusal: "different defect from a refused rebuild",
		},
		{
			id: "N3", name: "ineligible state: REBUILD_NOT_EXECUTED (unknown mutation history)",
			setup: func(h *harness) {
				writeFixtureState(t, h.in.StateDir, state.StateRebuildNotExecuted, "1.233.0")
			},
			wantRefusal: "NOT ESTABLISHED",
		},
		{
			id: "N4", name: "package identity mismatch",
			setup: func(h *harness) {
				h.mock.Files[fhs.VersionFile] = []byte("1.230.0")
			},
			wantRefusal: "does not match the record's INSTALL_VERSION",
		},
		{
			id: "N5", name: "daemon not active",
			setup: func(h *harness) {
				h.mock.RunResults["systemctl:is-active:nftband.service"] =
					executor.Result{ExitCode: 3, Stdout: "inactive\n"}
			},
			wantRefusal: "not active",
		},
		{
			id: "N6", name: "a BARE host-wide ct-count rule survives",
			setup: func(h *harness) {
				rs := strings.Replace(healthyRuleset,
					"tcp dport 80 add @connlimit_http_v4 { ip saddr ct count over 200 } drop # handle 8",
					"tcp dport 80 ct count over 200 drop # handle 8", 1)
				h.mock.RunResults["nft:-a:list:ruleset"] = executor.Result{ExitCode: 0, Stdout: rs}
			},
			wantRefusal: "BARE host-wide ct-count rule",
		},
		{
			id: "N7", name: "family/key correlation broken (v4 set keyed on ip6)",
			setup: func(h *harness) {
				rs := strings.Replace(healthyRuleset,
					"add @connlimit_ssh_v4 { ip saddr ct count over 15 }",
					"add @connlimit_ssh_v4 { ip6 saddr ct count over 15 }", 1)
				h.mock.RunResults["nft:-a:list:ruleset"] = executor.Result{ExitCode: 0, Stdout: rs}
			},
			wantRefusal: "family of the set and the family of its key selector disagree",
		},
		{
			id: "N8", name: "a service is governed on only one family",
			setup: func(h *harness) {
				rs := strings.Replace(healthyRuleset,
					"\t\ttcp dport 80 add @connlimit_http_v6 { ip6 saddr ct count over 200 } drop # handle 9\n", "", 1)
				h.mock.RunResults["nft:-a:list:ruleset"] = executor.Result{ExitCode: 0, Stdout: rs}
			},
			wantRefusal: "missing a family pair",
		},
		{
			id: "N9", name: "NO connlimit enforcement at all (the vacuous-pass guard)",
			setup: func(h *harness) {
				rs := "table ip nftban {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n\t}\n}\n"
				h.mock.RunResults["nft:-a:list:ruleset"] = executor.Result{ExitCode: 0, Stdout: rs}
			},
			wantRefusal: "no per-source enforcement to certify",
		},
		{
			id: "N10", name: "convergence committed DURING the proof",
			setup: func(h *harness) {
				// Fires while the ruleset is being read — between the two generation reads.
				h.mock.OnCommand(func() {
					h.mock.Files[genPath] = []byte("41\n")
				}, "nft", "-a", "list", "ruleset")
			},
			wantRefusal: "moved 40 -> 41 DURING the proof",
		},
		{
			id: "N11", name: "convergence authority not acquired",
			setup: func(h *harness) {
				acquireConvergence = func(time.Duration) (func(), error) {
					return nil, os.ErrDeadlineExceeded
				}
			},
			wantRefusal: "convergence authority not acquired",
		},
		{
			id: "N12", name: "generation counter unreadable (absence of evidence)",
			setup: func(h *harness) {
				delete(h.mock.Files, genPath)
			},
			wantRefusal: "UNREADABLE",
		},
		{
			id: "N13", name: "ruleset observation killed by its deadline",
			setup: func(h *harness) {
				h.mock.RunResults["nft:-a:list:ruleset"] = executor.Result{ExitCode: -1, TimedOut: true}
			},
			wantRefusal: "KILLED by its deadline",
		},
	}

	for _, tc := range cases {
		t.Run(tc.id+"_"+tc.name, func(t *testing.T) {
			h := newHarness(t)
			tc.setup(h)
			before := sha256File(t, h.stPath)

			out, err := Run(h.in)
			if err != nil {
				t.Fatalf("Run errored (a refusal is a RESULT, not an execution error): %v", err)
			}

			// ── the refusal itself ──
			if out.Reconciled {
				t.Fatalf("%s RECONCILED a host it must refuse", tc.id)
			}
			if !strings.Contains(out.Refusal, tc.wantRefusal) {
				t.Errorf("%s refusal does not name the actual defect\n  want substring: %q\n  got: %s",
					tc.id, tc.wantRefusal, out.Refusal)
			}

			// ── the shared invariants ──
			if after := sha256File(t, h.stPath); after != before {
				t.Errorf("%s MUTATED THE LIFECYCLE RECORD on a refusal\n  before %s\n  after  %s",
					tc.id, before, after)
			}
			if out.Event.StateSHA256Before != out.Event.StateSHA256After {
				t.Errorf("%s forensic event reports a record change on a refusal: %s -> %s",
					tc.id, out.Event.StateSHA256Before, out.Event.StateSHA256After)
			}
			assertNoRuntimeMutation(t, h)
			if out.Event.RuntimeMutated {
				t.Errorf("%s forensic event claims runtime_mutated=true", tc.id)
			}
			if out.Event.Outcome != "REFUSED" {
				t.Errorf("%s outcome = %q, want REFUSED", tc.id, out.Event.Outcome)
			}

			// the record must still hold its ORIGINAL state
			sf := state.NewStateFile(h.in.StateDir)
			if rerr := sf.Read(); rerr == nil && sf.State == state.StateCommitted {
				t.Errorf("%s left the record at COMMITTED", tc.id)
			}
		})
	}
}

// ═════════════════════════════════════════════════════════════════════════════
// ANTI-DRIFT — the eligibility control must be able to REJECT.
// ═════════════════════════════════════════════════════════════════════════════
// ⛔ A guard that only reads back what production computed proves nothing. These
// declare DELIBERATELY WRONG classifications and require them to be caught.
func TestValidateReconcileEligibility_RejectsWrongClaims(t *testing.T) {
	wrongTrue := []state.InstallState{
		state.StateDegraded, state.StateAppliedUnverified, state.StateRebuildNotExecuted,
		state.StateCommitted, state.StateFailedRebuild, state.StateFailedRender,
	}
	for _, s := range wrongTrue {
		if msg := state.ValidateReconcileEligibility(s, true); msg == "" {
			t.Errorf("%s was accepted as RECONCILE-eligible — the anti-drift control is decorative", s)
		}
	}
	if msg := state.ValidateReconcileEligibility(state.StateRebuildRefusedBusy, false); msg == "" {
		t.Error("REBUILD_REFUSED_BUSY declared ineligible was accepted — the control cannot reject " +
			"in the other direction either")
	}
	if msg := state.ValidateReconcileEligibility(state.StateRebuildRefusedBusy, true); msg != "" {
		t.Errorf("the one eligible state was rejected: %s", msg)
	}
	// Eligibility is exactly one state — proven by enumeration, not by assertion.
	eligible := 0
	for _, s := range []state.InstallState{
		state.StateFilesInstalled, state.StateDetectComplete, state.StatePrepareComplete,
		state.StateSwitchComplete, state.StateServicesComplete, state.StateCommitted,
		state.StateAppliedUnverified, state.StateDegraded, state.StateFailedSSH,
		state.StateFailedAbort, state.StateFailedRender, state.StateFailedRebuild,
		state.StateFailedNoFirewall, state.StateFailedTakeover, state.StateRebuildRefusedBusy,
		state.StateRebuildNotExecuted, state.StateFailedPreflightDiskSpace,
	} {
		if s.ReconcileEligible() {
			eligible++
			if s != state.StateRebuildRefusedBusy {
				t.Errorf("%s is reconcile-eligible — the lane admits exactly ONE state", s)
			}
		}
	}
	if eligible != 1 {
		t.Errorf("reconcile-eligible states = %d, want exactly 1", eligible)
	}
}
