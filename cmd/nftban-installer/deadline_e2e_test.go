// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// END-TO-END deadline matrix: drives runInstall / runRepair, not a pure function.
//
// The srv3 defect did NOT live inside any single function. It emerged from the
// interaction between the global context, an exempt rebuild, phase-loop ordering,
// terminal-state transitions, repair semantics and the separate update path. Decision
// tests cannot observe that interaction, so these drive the real loop and assert on the
// STATE FILE and the LOG, not only the returned exit code — the incident's whole shape
// was a correct subprocess result converted into an incorrect installer verdict.
//
// TIME IS SCALED, ORDER IS NOT. Waiting 318 real seconds per case would make this suite
// unrunnable. The harness passes runInstall a ctx whose deadline stands in for the global
// budget, and a mock rebuild that sleeps a scaled duration. What is reproduced is the
// ORDERING and the deadline STATE at each phase boundary, which is what the defect turned
// on. A genuinely slow run is covered separately on lab2/lab4.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/pkg/version"
)

// scaled budget: 120ms stands in for the 300s global budget.
const testBudget = 120 * time.Millisecond

// rebuildSim describes how the mocked rebuild behaves.
type rebuildSim struct {
	dur  time.Duration // scaled wall-clock the rebuild occupies
	exit int           // its exit code
}

type e2eResult struct {
	sf             *state.StateFile
	rc             int
	log            string
	reachedRebuild bool // the mocked rebuild was actually invoked
}

// driveInstall runs the real runInstall loop against the all-pass fixture, with the
// rebuild replaced by a controllable simulation.
func driveInstall(t *testing.T, budget time.Duration, sim rebuildSim) e2eResult {
	t.Helper()
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()

	dir := t.TempDir()
	t.Setenv("NFTBAN_MIN_DISK_FREE_MB", "1")
	m.Files["/etc/ssh/sshd_config"] = []byte("Port 22\n")

	// Satisfy the Prepare dependency gate. WITHOUT THIS the run dies in Prepare with
	// FAILED_RENDER and never reaches Switch — every assertion below would then pass
	// vacuously, "proving" the deadline logic while never executing a rebuild. The
	// harness asserts it actually reached the rebuild (see reachedRebuild).
	for _, c := range []string{
		"jq", "curl", "socat", "bc", "gawk", "getfacl", "tar", "nft", "systemctl",
		"install", "chown", "chmod", "setcap", "sed", "grep", "awk",
	} {
		m.ExistingCommands[c] = true
	}
	m.Files["/etc/os-release"] = []byte("ID=ubuntu\nVERSION_ID=\"24.04\"\n")

	// Intercept the rebuild: occupy `dur`, then return `exit`.
	invoked := false
	m.RunHook = func(name string, args []string) (executor.Result, bool) {
		if name == fhs.NftbanCLI && len(args) >= 2 && args[0] == "firewall" && args[1] == "rebuild" {
			invoked = true
			time.Sleep(sim.dur)
			// Publish the result record the real shell writes. The consumer validates a
			// schema_version and a disposition; a bare {"status":"ok"} is rejected as
			// "no usable result contract", which would make every case here fail for a
			// reason unrelated to deadlines.
			opID, resultPath := "", ""
			for i := 0; i < len(args)-1; i++ {
				switch args[i] {
				case "--result-file":
					resultPath = args[i+1]
				case "--operation-id":
					opID = args[i+1]
				}
			}
			if resultPath != "" {
				disp, committed, txReason := "COMPLETE", "true", "COMMITTED"
				if sim.exit != 0 {
					disp, committed, txReason = "FAILED", "false", "NONE"
				}
				body := fmt.Sprintf(`{"schema_version":"1","operation_id":%q,`+
					`"context":"install-deferred","disposition":%q,"reason_codes":["TEST"],`+
					`"rollback_performed":false,"transaction":{"committed":%s,"reason":%q},`+
					`"retry":{"reason":"NONE"},"pre_status":"protected",`+
					`"post_status":"protected","emitted_at":"2026-08-30T00:00:00Z"}`,
					opID, disp, committed, txReason)
				_ = os.WriteFile(resultPath, []byte(body), 0o640)
			}
			return executor.Result{ExitCode: sim.exit}, true
		}
		return executor.Result{}, false
	}

	sf := state.NewStateFile(dir)
	sf.Version = version.Version
	sf.SSHPort = 22
	cfg := &config{mode: "upgrade", stateDir: dir, inject: inj}
	globalPhaseData = phaseData{}
	logPath := dir + "/installer.log"
	log := logging.New(logPath, false)

	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()
	rc := runInstall(ctx, m, sf, cfg, log)

	b, _ := os.ReadFile(logPath)
	return e2eResult{sf: sf, rc: rc, log: string(b), reachedRebuild: invoked}
}

func (r e2eResult) says(s string) bool { return strings.Contains(r.log, s) }

// mustHaveReachedRebuild fails loudly when the run never got to Switch. Without it a
// harness that dies in an earlier phase reports every deadline assertion as PASS while
// exercising none of them.
func (r e2eResult) mustHaveReachedRebuild(t *testing.T) {
	t.Helper()
	if !r.reachedRebuild {
		t.Fatalf("VACUOUS: the run never invoked the rebuild, so this case proves nothing "+
			"about deadline handling (state=%s rc=%d)\n%s", r.sf.State, r.rc, r.log)
	}
}

// ---- class 1 & 2: bounded and long-but-healthy -------------------------------

// A rebuild well inside the budget must simply succeed.
func TestE2E_RebuildFastWithinBudget_NoFalseFailure(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 5 * time.Millisecond, exit: 0})
	r.mustHaveReachedRebuild(t)
	if r.sf.State == state.StateFailedRebuild {
		t.Fatalf("fast successful rebuild recorded FAILED_REBUILD (rc=%d)\n%s", r.rc, r.log)
	}
}

// Just inside the budget — the boundary case that must NOT tip into failure.
func TestE2E_RebuildJustInsideBudget_NoFalseFailure(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 100 * time.Millisecond, exit: 0})
	r.mustHaveReachedRebuild(t)
	if r.sf.State == state.StateFailedRebuild {
		t.Fatalf("rebuild just inside budget recorded FAILED_REBUILD (rc=%d)\n%s", r.rc, r.log)
	}
}

// THE PRODUCTION SHAPE. Rebuild outlives the global budget and SUCCEEDS. Before the fix
// this produced FAILED_REBUILD naming a phase that never ran, on a healthy host.
func TestE2E_RebuildOutlivesBudgetButSucceeds_NoFalseFailure(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 200 * time.Millisecond, exit: 0})
	r.mustHaveReachedRebuild(t)
	if r.sf.State == state.StateFailedRebuild {
		t.Fatalf("SRV3 REGRESSION: successful rebuild that outlived the budget was recorded "+
			"FAILED_REBUILD (rc=%d)\n%s", r.rc, r.log)
	}
	if !r.says("exempt by policy and completed successfully") {
		t.Errorf("no credit evidence logged; the run must record WHY it continued\n%s", r.log)
	}
	if !r.says("granting a single fresh budget") {
		t.Errorf("post-exempt continuation not logged as bounded\n%s", r.log)
	}
	// attribution must never name a phase that did not run
	if r.says("during phase Configure") {
		t.Errorf("mis-attribution regressed: named a phase that never started\n%s", r.log)
	}
}

// ---- class 5: attribution ----------------------------------------------------

// Rebuild FAILS: that is a real failure and must stay one.
func TestE2E_RebuildGenuinelyFails_StaysAFailure(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 5 * time.Millisecond, exit: 2})
	r.mustHaveReachedRebuild(t)
	if !r.sf.State.IsFailed() {
		t.Fatalf("a genuinely failing rebuild was not recorded as failed: state=%s rc=%d\n%s",
			r.sf.State, r.rc, r.log)
	}
	if r.says("exempt by policy and completed successfully") {
		t.Errorf("credit granted for a FAILED exempt operation — it must never buy budget\n%s", r.log)
	}
}

// Rebuild outlives the budget AND fails: no credit, and the failure is attributed.
func TestE2E_RebuildOutlivesBudgetAndFails_NoCredit(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 200 * time.Millisecond, exit: 2})
	r.mustHaveReachedRebuild(t)
	if !r.sf.State.IsFailed() {
		t.Fatalf("failing rebuild past the budget was not recorded as failed: %s\n%s",
			r.sf.State, r.log)
	}
	if r.says("exempt by policy and completed successfully") {
		t.Errorf("credit granted to a failed rebuild\n%s", r.log)
	}
}

// Budget already gone before anything ran: the first phase must not be blamed.
func TestE2E_ExpiredBeforeAnyPhase_DoesNotBlameFirstPhase(t *testing.T) {
	r := driveInstall(t, 1*time.Nanosecond, rebuildSim{dur: time.Millisecond, exit: 0})
	if !r.says("was not entered") {
		t.Errorf("expiry before any phase did not state that the phase was not entered\n%s", r.log)
	}
	if r.says("during phase Detect") {
		t.Errorf("blamed Detect, which never started\n%s", r.log)
	}
	if r.sf.State == state.StateCommitted {
		t.Errorf("run with an already-expired budget was recorded COMMITTED")
	}
}

// ---- repair path -------------------------------------------------------------

// A repair killed by the deadline must write an explicit terminal state, never leave
// whatever happened to be on disk.
func TestE2E_RepairExpired_WritesExplicitTerminalState(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	dir := t.TempDir()
	t.Setenv("NFTBAN_MIN_DISK_FREE_MB", "1")
	m.Files["/etc/ssh/sshd_config"] = []byte("Port 22\n")
	sf := state.NewStateFile(dir)
	sf.State = state.StateDegraded
	sf.Version = version.Version
	sf.SSHPort = 22
	cfg := &config{repair: true, stateDir: dir, inject: inj}
	globalPhaseData = phaseData{}
	logPath := dir + "/installer.log"
	log := logging.New(logPath, false)

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Nanosecond)
	defer cancel()
	_ = runRepair(ctx, m, sf, cfg, log)

	b, _ := os.ReadFile(logPath)
	out := string(b)
	if !strings.Contains(out, "repair") || !strings.Contains(out, "was not entered") {
		t.Errorf("expired repair did not log an attributed outcome\n%s", out)
	}
	if sf.State == state.StateDegraded {
		t.Errorf("expired repair left the PRE-EXISTING state (%s) — indistinguishable from "+
			"a repair that never started; it must record its own outcome", sf.State)
	}
}
