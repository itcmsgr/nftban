// =============================================================================
// NFTBan v1.230.0 Gate 6R F2 — RECOVERY_CLASS, executed end to end
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-recovery-contract-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="Proves the recovery instruction emitted for REBUILD_REFUSED_BUSY actually recovers: the recovery the declared RECOVERY_CLASS names is EXECUTED against the refused host and must reach COMMITTED, while the mechanism a wrong class would have named is executed too and must NOT. Includes the declared-inversion negative control that misclassifying REBUILD_REFUSED_BUSY as REPAIR fails the guard."
// meta:inventory.files="cmd/nftban-installer/recovery_contract_v1230_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	coresafety "github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/pkg/version"
)

// recoveryHost is a host that can genuinely reach COMMITTED, so "did the recovery work?"
// is a real question rather than one the fixture answers no to for unrelated reasons.
type recoveryHost struct {
	m       *executor.MockExecutor
	cfg     *config
	dir     string
	refused bool   // while true, the shell's convergence lock is held
	logRoot string // hermetic root: every log-retention artifact lives below this
	logDir  string // the relocated /var/log/nftban inside logRoot
}

func newRecoveryHost(t *testing.T) *recoveryHost {
	t.Helper()
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	t.Cleanup(cleanup)
	// ⛔ THE REAL logrotate VALIDATOR RUNS HERE. newAllAssertionsPassFixture injects a
	// stub that returns success unconditionally; that is right for arms about OTHER
	// assertions, but here it would BYPASS logretention_policy_ready entirely and the
	// NC2 control (corrupt the policy, the assertion must still fail) could not hold.
	inj.logRetentionValidator = nil
	// The shipped policy, materialised entirely under a temp root, so the check is real
	// AND independent of whether this host has /var/log/nftban.
	h := &recoveryHost{}
	h.logRoot = t.TempDir()
	h.logDir = hermeticLogretention(t, h.logRoot)
	// The health verdict is computed from the REAL /proc of whatever host runs this, so
	// the effective values are seeded from the SAME canonical function the installer
	// uses. ⛔ Not a hardcoded tier: that would pass on lab2 and fail in CI.
	p := coresafety.HealthServiceMemoryLimits()
	m.RunResults[healthShowKey()] = executor.Result{
		Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile),
	}
	t.Setenv("NFTBAN_MIN_DISK_FREE_MB", "1")
	m.Files["/etc/ssh/sshd_config"] = []byte("Port 22\n")
	t.Cleanup(switchop.SetRebuildResultBaseDirForTest(t.TempDir()))
	for _, c := range []string{
		"jq", "curl", "socat", "bc", "gawk", "getfacl", "tar", "nft", "systemctl",
		"install", "chown", "chmod", "setcap", "sed", "grep", "awk",
	} {
		m.ExistingCommands[c] = true
	}
	m.Files["/etc/os-release"] = []byte("ID=ubuntu\nVERSION_ID=\"24.04\"\n")
	m.Files[switchop.BootProjectionPath] = []byte("table ip nftban {\n}\n")
	m.Files[switchop.ConvergenceGenerationPath] = []byte("7\n")
	m.NftTables["ip:nftban"] = true
	m.NftTables["ip6:nftban"] = true

	h.m, h.dir = m, t.TempDir()
	h.cfg = &config{mode: "upgrade", stateDir: h.dir, inject: inj}
	gen := 7
	m.RunHook = func(name string, args []string) (executor.Result, bool) {
		if name != fhs.NftbanCLI || len(args) < 2 || args[0] != "firewall" || args[1] != "rebuild" {
			return executor.Result{}, false
		}
		var rp, op, wp string
		for i := 0; i < len(args)-1; i++ {
			switch args[i] {
			case "--result-file":
				rp = args[i+1]
			case "--operation-id":
				op = args[i+1]
			case "--execution-witness":
				wp = args[i+1]
			}
		}
		if h.refused {
			// Refused BEFORE any mutation: no witness, no generation advance.
			body := `{"schema_version":"1","operation_id":"` + op + `","context":"install-deferred",` +
				`"disposition":"REFUSED","reason_codes":["CONVERGENCE_LOCK_HELD"],"rollback_performed":false,` +
				`"modified":false,"enforcement_unchanged":true,` +
				`"transaction":{"committed":false,"reason":"NOT_STARTED"},"retry":{"reason":"REFUSED_CONVERGENCE_LOCK"},` +
				`"pre_status":"not-observed","post_status":"not-observed","emitted_at":"2026-09-13T00:00:00Z"}`
			_ = os.MkdirAll(filepath.Dir(rp), 0o750)
			_ = os.WriteFile(rp, []byte(body), 0o640)
			return executor.Result{ExitCode: 1}, true
		}
		if wp != "" {
			_ = os.MkdirAll(filepath.Dir(wp), 0o750)
			_ = os.WriteFile(wp, []byte("operation_id="+op+"\n"), 0o640)
		}
		gen++
		m.Files[switchop.ConvergenceGenerationPath] = []byte(itoaLine(gen))
		body := `{"schema_version":"1","operation_id":"` + op + `","context":"install-deferred",` +
			`"disposition":"COMPLETE","reason_codes":[],"rollback_performed":false,` +
			`"modified":true,"enforcement_unchanged":false,` +
			`"transaction":{"committed":true,"reason":"COMMITTED"},"retry":{"reason":"NONE"},` +
			`"pre_status":"protected","post_status":"protected","emitted_at":"2026-09-13T00:00:00Z"}`
		_ = os.MkdirAll(filepath.Dir(rp), 0o750)
		_ = os.WriteFile(rp, []byte(body), 0o640)
		return executor.Result{ExitCode: 0}, true
	}
	return h
}

func itoaLine(n int) string {
	d := []byte{}
	if n == 0 {
		d = []byte{'0'}
	}
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(append(d, '\n'))
}

// runTransaction executes the NORMAL update/install transaction — the operation the
// RETRY_FULL_TRANSACTION instruction names.
func (h *recoveryHost) runTransaction(t *testing.T) (*state.StateFile, int, string) {
	t.Helper()
	return h.run(t, false)
}

// runRepairMechanism executes `nftban-installer --repair` — the operation a REPAIR
// classification would have named.
func (h *recoveryHost) runRepairMechanism(t *testing.T) (*state.StateFile, int, string) {
	t.Helper()
	return h.run(t, true)
}

func (h *recoveryHost) run(t *testing.T, repair bool) (*state.StateFile, int, string) {
	t.Helper()
	sf := state.NewStateFile(h.dir)
	_ = sf.Read()
	sf.Version = version.Version
	if sf.SSHPort == 0 {
		sf.SSHPort = 22
	}
	globalPhaseData = phaseData{}
	// Mirror the production wiring at main.go:263 — without it the DATA injection
	// carrier never reaches phaseValidate and the systemd-payload assertions gather
	// from the REAL host, which is another way this arm could pass on a provisioned
	// box and fail on a bare runner.
	globalPhaseData.inject = h.cfg.inject
	logPath := filepath.Join(h.dir, "installer.log")
	_ = os.Remove(logPath)
	log := logging.New(logPath, false)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cfg := *h.cfg
	cfg.repair = repair
	var rc int
	if repair {
		rc = runRepair(ctx, h.m, sf, &cfg, log)
	} else {
		rc = runInstall(ctx, h.m, sf, &cfg, log)
	}
	log.Close()
	b, _ := os.ReadFile(logPath)
	return sf, rc, string(b)
}

// ─────────────────────────────────────────────────────────────────────────────
// F2 — the printed instruction is EXECUTED, and the host must reach COMMITTED
// ─────────────────────────────────────────────────────────────────────────────
//
// ⛔ SCOPE OF THIS PROOF, STATED PLAINLY. It executes the OPERATION the instruction
// names, through the real entry points (runInstall / runRepair), against a mock host,
// and asserts the terminal install state. It does NOT shell out to a command line and
// does NOT exercise dpkg/rpm. Package-native execution of the same instruction is a lab
// arm, not a hermetic one. What is hermetic here is the part that was wrong on lab3:
// which MECHANISM is advertised, and whether that mechanism reaches COMMITTED.
func TestF2_RefusedBusy_TheAdvertisedRecoveryActuallyRecovers(t *testing.T) {
	h := newRecoveryHost(t)
	defer switchop.SetRefusalBackoffForTest(time.Millisecond, 2*time.Millisecond)()

	// 1. Produce the refused host.
	h.refused = true
	sf, _, refusedLog := h.runTransaction(t)
	if sf.State != state.StateRebuildRefusedBusy {
		t.Fatalf("setup: state = %s, want REBUILD_REFUSED_BUSY\n%s", sf.State, refusedLog)
	}
	// The emitted contract must say the three required things.
	if !strings.Contains(refusedLog, "RECOVERY_CLASS=RETRY_FULL_TRANSACTION") {
		t.Errorf("the recovery class was not declared\n%s", refusedLog)
	}
	if !strings.Contains(refusedLog, "ENFORCEMENT") || !strings.Contains(refusedLog, "LEFT UNCHANGED") {
		t.Errorf("the operator was not told enforcement remained unchanged\n%s", refusedLog)
	}
	if sf.State == state.StateCommitted {
		t.Fatal("a refused run must remain NOT_COMMITTED")
	}

	// 2. EXECUTE the instruction: the conflicting operation finished, so re-run the
	//    normal transaction.
	h.refused = false
	after, rc, retryLog := h.runTransaction(t)
	if after.State != state.StateCommitted {
		t.Fatalf("the ADVERTISED recovery did not reach COMMITTED: state=%s rc=%d\n%s", after.State, rc, retryLog)
	}
	if rc != state.ExitCommitted {
		t.Errorf("rc = %d, want %d after a successful recovery", rc, state.ExitCommitted)
	}
	if after.ConvergenceVerified != string(switchop.ConvergenceVerified) {
		t.Errorf("recovered host records CONVERGENCE_VERIFIED=%q, want VERIFIED", after.ConvergenceVerified)
	}

	// ── the seven acceptance criteria, checked explicitly on this run ────────────
	h.assertHermetic(t, retryLog)
	// 4. convergence and the other recovery-relevant assertions.
	for _, want := range []string{
		"ASSERT post_update_convergence_verified: PASS",
		"PASS projection_generated",
		"PASS effective_generation",
		"PASS kernel_tables_present",
	} {
		if !strings.Contains(retryLog, want) {
			t.Errorf("criterion 4: %q not observed in the recovered run\n%s", want, retryLog)
		}
	}
	if strings.Contains(retryLog, "ASSERT whitelist_convergence_ok: FAIL") {
		t.Errorf("criterion 4: whitelist_convergence_ok failed\n%s", retryLog)
	}
	// 5. the UNRELATED policy assertion passed against the hermetic fixture — and
	//    passed for the right reason, having actually run the validator.
	if strings.Contains(retryLog, "ASSERT logretention_policy_ready: FAIL") {
		t.Errorf("criterion 5: logretention_policy_ready failed against the hermetic fixture\n%s", retryLog)
	}
	if !strings.Contains(retryLog, "logretention_policy_ready: PASS") {
		t.Errorf("criterion 5: logretention_policy_ready did not report a pass\n%s", retryLog)
	}
}

// assertHermetic checks criteria 1, 2 and 7: the arm must be INDEPENDENT of the host's
// /var/log/nftban, every artifact must live under the temp root, and nothing may be
// written to a global path.
//
// ⛔ IT DOES NOT ASSERT THAT THE HOST LACKS /var/log/nftban. lab2 and lab4 have nftban
// installed, so requiring absence would fail there — and "the host happens not to have
// it" is not what hermetic means. What is asserted is that the policy under test cannot
// reach the host path at all, which holds on a provisioned box and a bare runner alike.
func (h *recoveryHost) assertHermetic(t *testing.T, runLog string) {
	t.Helper()
	// 1 + 2: every log-retention input is rooted in the temp tree.
	for _, k := range []string{"NFTBAN_LR_MAIN", "NFTBAN_LR_TEMPLATE", "NFTBAN_LR_STATE", "NFTBAN_LR_SURICATA"} {
		v := os.Getenv(k)
		if v == "" || !strings.HasPrefix(v, h.logRoot) {
			t.Errorf("criterion 2: %s=%q is not under the hermetic root %s", k, v, h.logRoot)
		}
	}
	body, err := os.ReadFile(os.Getenv("NFTBAN_LR_MAIN"))
	if err != nil {
		t.Fatalf("criterion 2: cannot read the active policy: %v", err)
	}
	// 1: the policy the validator saw names ONLY the relocated root. Every occurrence of
	// the host token must be the tail of a temp path.
	if strings.Count(string(body), "/var/log/nftban") != strings.Count(string(body), h.logDir) {
		t.Errorf("criterion 1: the validated policy still names the HOST log root — this arm " +
			"would pass or fail depending on whether the runner has nftban installed")
	}
	// 7: nothing written to a global path by the installer under test.
	for p := range h.m.WrittenFiles {
		if strings.HasPrefix(p, "/var/log/nftban") || strings.HasPrefix(p, "/etc/logrotate.d") {
			t.Errorf("criterion 7: the run wrote to a global path: %s", p)
		}
	}
	// And the fixture itself created nothing outside the temp root: the only paths it
	// touches are derived from h.logRoot by construction (hermeticLogretention), which
	// this re-asserts against the actual tree.
	seen := 0
	_ = filepath.WalkDir(h.logDir, func(p string, _ fs.DirEntry, e error) error {
		if e == nil && strings.HasPrefix(p, h.logRoot) {
			seen++
		}
		return nil
	})
	if seen == 0 {
		t.Error("criterion 2: the hermetic log tree is empty — the fixture materialised nothing")
	}
}

// ⛔ THE MECHANISM WE REFUSE TO ADVERTISE MUST ACTUALLY FAIL, or the refusal is
// superstition. This reproduces the lab3 run: --repair from REBUILD_REFUSED_BUSY.
func TestF2_RepairFromRefusedBusy_DoesNotReachCommitted(t *testing.T) {
	h := newRecoveryHost(t)
	defer switchop.SetRefusalBackoffForTest(time.Millisecond, 2*time.Millisecond)()

	h.refused = true
	sf, _, _ := h.runTransaction(t)
	if sf.State != state.StateRebuildRefusedBusy {
		t.Fatalf("setup: state = %s", sf.State)
	}

	// The lock is free now — --repair's rebuild WILL run and commit a generation, which
	// is exactly what made the lab3 outcome so misleading.
	h.refused = false
	after, rc, repairLog := h.runRepairMechanism(t)
	if after.State == state.StateCommitted {
		t.Fatalf("--repair reached COMMITTED from REBUILD_REFUSED_BUSY — then RECOVERY_CLASS "+
			"should be REPAIR and this release's instruction is wrong\n%s", repairLog)
	}
	// And it must fail for the REASON the class derivation gives: the render is skipped.
	if !strings.Contains(repairLog, "FAIL projection_generated") {
		t.Errorf("--repair failed for a different reason than the derivation claims (rc=%d state=%s)\n%s",
			rc, after.State, repairLog)
	}
	if after.ConvergenceVerified != string(switchop.ConvergenceNotConverged) {
		t.Errorf("CONVERGENCE_VERIFIED = %q, want NOT_CONVERGED", after.ConvergenceVerified)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// The anti-drift guard, and the declared inversion that makes it real
// ─────────────────────────────────────────────────────────────────────────────
func TestF2_RecoveryClassGuard_AcceptsTheCorrectClassification(t *testing.T) {
	for _, s := range []state.InstallState{
		state.StateRebuildRefusedBusy,
		state.StateRebuildNotExecuted,
		state.StateFailedRebuild,
		state.StateDegraded,
		state.StateFailedAbort,
	} {
		if why := state.ValidateRecoveryClass(s, s.RecoveryClass()); why != "" {
			t.Errorf("the derived class for %s was rejected by its own guard: %s", s, why)
		}
	}
}

// ⛔ THE NEGATIVE CONTROL. Deliberately misclassify REBUILD_REFUSED_BUSY as REPAIR — the
// exact defect lab3 found — and require the guard to REJECT it, naming why. If this ever
// passes, the control is decorative and the defect can return as prose drift.
func TestF2_RecoveryClassGuard_RejectsTheLab3Misclassification(t *testing.T) {
	why := state.ValidateRecoveryClass(state.StateRebuildRefusedBusy, state.RecoveryRepair)
	if why == "" {
		t.Fatal("declaring REBUILD_REFUSED_BUSY as RECOVERY_CLASS=REPAIR was ACCEPTED — " +
			"the guard cannot detect the defect the live lab3 run found")
	}
	for _, want := range []string{"REBUILD_REFUSED_BUSY", "REPAIR", "SWITCH", "no demonstrated route to COMMITTED"} {
		if !strings.Contains(why, want) {
			t.Errorf("the rejection must name %q; got: %s", want, why)
		}
	}
	// ⛔ AND IT MUST NOT REJECT INDISCRIMINATELY: a state --repair genuinely recovers
	// must still be allowed to declare REPAIR, or the guard is just "always no".
	if why := state.ValidateRecoveryClass(state.StateDegraded, state.RecoveryRepair); why != "" {
		t.Errorf("DEGRADED legitimately recovers via --repair and must be accepted: %s", why)
	}
	// The opposite misclassification is also caught.
	if state.ValidateRecoveryClass(state.StateDegraded, state.RecoveryRetryFullTransaction) == "" {
		t.Error("under-claiming REPAIR for DEGRADED must also be rejected")
	}
}

// ⛔ SEMANTIC, NOT TEXTUAL. The class must be bound to whether a route to COMMITTED
// exists, which is derived from ResumePhase — not to whether a sentence says "--repair".
func TestF2_RecoveryClassIsDerivedFromTheResumeGraph(t *testing.T) {
	if state.StateRebuildRefusedBusy.ResumePhase() != state.PhaseSwitch {
		t.Fatal("fixture assumption broken: REBUILD_REFUSED_BUSY no longer resumes at SWITCH")
	}
	if state.StateRebuildRefusedBusy.RepairReachesCommitted() {
		t.Error("a SWITCH resume skips the boot-projection render; it cannot reach COMMITTED")
	}
	if !state.StateDegraded.RepairReachesCommitted() {
		t.Error("a VALIDATE resume runs no rebuild, so the recorded convergence verdict still applies")
	}
	// Every state that resumes at SWITCH must classify the same way, by construction —
	// so a future state added to that resume group cannot silently inherit REPAIR.
	for _, s := range []state.InstallState{
		state.StateRebuildRefusedBusy, state.StateRebuildNotExecuted,
		state.StateFailedRebuild, state.StateFailedNoFirewall, state.StateFailedTakeover,
	} {
		if s.ResumePhase() != state.PhaseSwitch {
			continue
		}
		if got := s.RecoveryClass(); got != state.RecoveryRetryFullTransaction {
			t.Errorf("%s resumes at SWITCH but declares %s", s, got)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// NC1 — the hermetic fixture is load-bearing, and the CI failure is reproduced
// ─────────────────────────────────────────────────────────────────────────────
// ⛔ A FINDING THAT CHANGED THIS CONTROL, REPORTED RATHER THAN PAPERED OVER.
// The literal control asked for was "remove the hermetic bans.log -> NOT_READY". That
// does NOT hold against the SHIPPED policy, and for a good reason: every stanza in
// install/config/nftban.logrotate declares `missingok` (17 of them), so a missing log is
// tolerated BY DESIGN. The CI failure was therefore an artifact of the SIMPLIFIED
// test-only policy the old fixture synthesised — which had no `missingok` and so was
// strictly less tolerant than what ships. Adopting the canonical policy removes the CI
// failure at its root rather than working around it.
//
// Both halves of the intent are still proven, and arm B reproduces the CI failure
// verbatim inside the temp tree — no host path involved:
//
//	A  remove the hermetic POLICY        -> NOT_READY -> DEGRADED -> restore -> COMMITTED
//	B  substitute the PRE-FIX simplified -> the exact CI error -> restore -> COMMITTED
//	   policy naming an absent log
func TestF2_NC1_TheHermeticFixtureIsLoadBearing(t *testing.T) {
	h := newRecoveryHost(t)
	defer switchop.SetRefusalBackoffForTest(time.Millisecond, 2*time.Millisecond)()
	h.refused = false

	mainPath := os.Getenv("NFTBAN_LR_MAIN")
	good, err := os.ReadFile(mainPath)
	if err != nil {
		t.Fatalf("read hermetic policy: %v", err)
	}
	restore := func() {
		if werr := os.WriteFile(mainPath, good, 0o644); werr != nil { // #nosec G306 -- logrotate policy is 0644 by contract
			t.Fatalf("restore policy: %v", werr)
		}
		if cerr := os.Chmod(mainPath, 0o644); cerr != nil {
			t.Fatalf("chmod policy: %v", cerr)
		}
	}

	// ── arm A: the fixture's policy is what makes the arm pass ───────────────────
	if err := os.Remove(mainPath); err != nil {
		t.Fatalf("remove hermetic policy: %v", err)
	}
	after, _, runLog := h.runTransaction(t)
	if after.State == state.StateCommitted {
		t.Fatalf("NC1-A did not reproduce: COMMITTED with NO active policy — "+
			"logretention_policy_ready is not being exercised at all\n%s", runLog)
	}
	if !strings.Contains(runLog, "ASSERT logretention_policy_ready: FAIL") ||
		!strings.Contains(runLog, "policy file missing") {
		t.Errorf("NC1-A: the failure did not come from the missing policy\n%s", runLog)
	}
	restore()
	if back, _, backLog := h.runTransaction(t); back.State != state.StateCommitted {
		t.Fatalf("NC1-A: restoring the policy did not restore COMMITTED (state=%s)\n%s", back.State, backLog)
	}

	// ── arm B: the CI failure, reproduced inside the temp tree ───────────────────
	// This is the PRE-FIX fixture shape: a synthesised policy with no `missingok`,
	// naming a log that does not exist. ⛔ It is used ONLY as a corrupted subject for
	// this control — never as the policy the passing path validates.
	absent := filepath.Join(h.logDir, "definitely-absent.log")
	preFix := absent + " {\n    daily\n    rotate 7\n    size 10M\n}\n"
	tmplPath := os.Getenv("NFTBAN_LR_TEMPLATE")
	goodTmpl, err := os.ReadFile(tmplPath)
	if err != nil {
		t.Fatalf("read hermetic template: %v", err)
	}
	for _, p := range []string{mainPath, tmplPath} {
		if werr := os.WriteFile(p, []byte(preFix), 0o644); werr != nil { // #nosec G306 -- logrotate policy is 0644 by contract
			t.Fatalf("write pre-fix policy %s: %v", p, werr)
		}
		if cerr := os.Chmod(p, 0o644); cerr != nil {
			t.Fatalf("chmod %s: %v", p, cerr)
		}
	}
	after, _, runLog = h.runTransaction(t)
	if after.State == state.StateCommitted {
		t.Fatalf("NC1-B did not reproduce the CI failure\n%s", runLog)
	}
	if !strings.Contains(runLog, "No such file or directory") {
		t.Errorf("NC1-B: the reproduced failure is not the missing-log one CI reported\n%s", runLog)
	}
	if !strings.Contains(runLog, "failed logrotate validation") {
		t.Errorf("NC1-B: the failure did not come from the validator\n%s", runLog)
	}
	restore()
	if werr := os.WriteFile(tmplPath, goodTmpl, 0o644); werr != nil { // #nosec G306 -- logrotate policy is 0644 by contract
		t.Fatalf("restore template: %v", werr)
	}
	if cerr := os.Chmod(tmplPath, 0o644); cerr != nil {
		t.Fatalf("chmod template: %v", cerr)
	}
	back, _, backLog := h.runTransaction(t)
	if back.State != state.StateCommitted {
		t.Fatalf("NC1-B: restoring the canonical policy did not restore COMMITTED (state=%s)\n%s",
			back.State, backLog)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// NC2 — an INVALID policy must still fail: the assertion is not neutered
// ─────────────────────────────────────────────────────────────────────────────
// ⛔ THE CONTROL THAT MATTERS MOST. NC1 only shows the target file is load-bearing. This
// shows the VALIDATOR itself is load-bearing: the policy is corrupted with a real
// logrotate syntax error while every OTHER gate is kept satisfiable — the active policy
// and the fallback template stay byte-identical, so the hash-identity classification
// still matches and the ONLY thing that can fail is `logrotate -d`.
//
// If this passed, the fixture would have replaced a real check with a decorative one.
func TestF2_NC2_AnInvalidPolicyStillFailsTheAssertion(t *testing.T) {
	h := newRecoveryHost(t)
	defer switchop.SetRefusalBackoffForTest(time.Millisecond, 2*time.Millisecond)()

	mainPath := os.Getenv("NFTBAN_LR_MAIN")
	tmplPath := os.Getenv("NFTBAN_LR_TEMPLATE")
	good, err := os.ReadFile(mainPath)
	if err != nil {
		t.Fatalf("read hermetic policy: %v", err)
	}
	// A directive logrotate rejects at parse time. Appended to BOTH files so the
	// fallback identity hash still matches and this cannot pass/fail for that reason.
	bad := append(append([]byte{}, good...), []byte("\nthis-is-not-a-logrotate-directive {\n    nonsense\n}\n")...)
	for _, p := range []string{mainPath, tmplPath} {
		if err := os.WriteFile(p, bad, 0o644); err != nil { // #nosec G306 -- logrotate policy is 0644 by contract
			t.Fatalf("corrupt %s: %v", p, err)
		}
		if err := os.Chmod(p, 0o644); err != nil {
			t.Fatalf("chmod %s: %v", p, err)
		}
	}

	h.refused = false
	after, _, runLog := h.runTransaction(t)
	if after.State == state.StateCommitted {
		t.Fatalf("NC2 FAILED: an INVALID logrotate policy still reached COMMITTED — "+
			"logretention_policy_ready has been neutered, not given a valid environment\n%s", runLog)
	}
	if !strings.Contains(runLog, "ASSERT logretention_policy_ready: FAIL") {
		t.Errorf("NC2: the invalid policy did not fail the policy assertion\n%s", runLog)
	}
	// ⛔ AND IT MUST FAIL THROUGH THE VALIDATOR, not through the hash-identity gate —
	// otherwise `logrotate -d` might never have run at all.
	if !strings.Contains(runLog, "failed logrotate validation") {
		t.Errorf("NC2: the failure did not come from the logrotate validator, so the real "+
			"validator may not be running\n%s", runLog)
	}

	// Restore and confirm the corruption was the only cause.
	for _, p := range []string{mainPath, tmplPath} {
		if err := os.WriteFile(p, good, 0o644); err != nil { // #nosec G306 -- logrotate policy is 0644 by contract
			t.Fatalf("restore %s: %v", p, err)
		}
		if err := os.Chmod(p, 0o644); err != nil {
			t.Fatalf("chmod %s: %v", p, err)
		}
	}
	restored, _, restoredLog := h.runTransaction(t)
	if restored.State != state.StateCommitted {
		t.Fatalf("NC2: restoring the valid policy did not restore COMMITTED (state=%s)\n%s",
			restored.State, restoredLog)
	}
}
