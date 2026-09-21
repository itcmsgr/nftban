// =============================================================================
// NFTBan v1.99 PR-18 — Update Apply Call-Path Purity Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftban-installer-update-apply-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Verify runUpdateApply is a thin sequencer and nothing more"
// meta:inventory.files="cmd/nftban-installer/update_apply_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// These tests run every MockExecutor.Commands trace from a runUpdateApply
// execution through the contract-audit harness in
// internal/installer/update/apply_contract_test.go. If apply ever invokes
// a command outside the whitelist, or writes to a forbidden path, the
// tests fail — before CI sees it.
//
// Coverage:
//   T1 happy path — preflight + rebuild + validator all pass → exit 0
//   T2 preflight fails → rebuild NEVER invoked → exit 1
//   T3 rebuild fails → validator NEVER invoked → exit = rebuild's RC
//   T4 rebuild OK but validator fails → exit = validator's RC (G3-U8
//      truth gate — validator wins)
//   T5 call-path purity — no command outside applyWhitelist ever invoked
//   T6 .conf.local byte-preservation — no write to *.conf.local (G3-U5)
//
// =============================================================================

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/internal/installer/update"
)

func newApplyTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

// seedHappyApplyHost populates a mock where:
//   - preflight passes (P-1..P-7 all OK)
//   - nftban firewall rebuild returns exit 0
//   - nftban-validate --json returns exit 0 with a valid "protected" body
//   - post-state inspection finds expected kernel + service state
//
// applyRebuildShell installs a RunHook that plays the SHELL for this plane's
// `nftban firewall rebuild` invocation.
//
// ⛔ v1.230.0 Gate 6R: apply now consumes the RESULT CONTRACT, not the exit code. A
// fixture that only sets an rc models a shell that published nothing, which is a
// different event entirely (execution not established) and would make every case here
// prove something other than what it claims.
//
// It also advances /run/nftban/convergence-generation on a COMPLETE, because that is
// what nftban_plan_txn_commit does and apply now cross-checks the claim against it.
func applyRebuildShell(t *testing.T, m *executor.MockExecutor, disposition string, rc int) {
	t.Helper()
	t.Cleanup(switchop.SetRebuildResultBaseDirForTest(t.TempDir()))
	m.Files[switchop.ConvergenceGenerationPath] = []byte("7\n")
	m.RunHook = func(name string, args []string) (executor.Result, bool) {
		if name != "nftban" || len(args) < 2 || args[0] != "firewall" || args[1] != "rebuild" {
			return executor.Result{}, false
		}
		var resultPath, opID, witness string
		for i := 0; i < len(args)-1; i++ {
			switch args[i] {
			case "--result-file":
				resultPath = args[i+1]
			case "--operation-id":
				opID = args[i+1]
			case "--execution-witness":
				witness = args[i+1]
			}
		}
		if witness != "" && disposition != "REFUSED" {
			_ = os.MkdirAll(filepath.Dir(witness), 0o750)
			_ = os.WriteFile(witness, []byte("operation_id="+opID+"\n"), 0o640)
		}
		if resultPath != "" && disposition != "" {
			committed, txReason, rollback := "false", "FAILURE", "false"
			modified, unchanged := "true", "false"
			switch disposition {
			case "COMPLETE":
				committed, txReason = "true", "COMMITTED"
				m.Files[switchop.ConvergenceGenerationPath] = []byte("8\n")
			case "REGRESSION":
				rollback = "true"
			case "REFUSED":
				txReason, modified, unchanged = "NOT_STARTED", "false", "true"
			}
			body := fmt.Sprintf(`{"schema_version":"1","operation_id":%q,"context":"runtime-required",`+
				`"disposition":%q,"reason_codes":["TEST"],"rollback_performed":%s,`+
				`"modified":%s,"enforcement_unchanged":%s,`+
				`"transaction":{"committed":%s,"reason":%q},"retry":{"reason":"NONE"},`+
				`"pre_status":"protected","post_status":"protected","emitted_at":"2026-09-13T00:00:00Z"}`,
				opID, disposition, rollback, modified, unchanged, committed, txReason)
			_ = os.MkdirAll(filepath.Dir(resultPath), 0o750)
			_ = os.WriteFile(resultPath, []byte(body), 0o640)
		}
		return executor.Result{ExitCode: rc}, true
	}
}

func seedHappyApplyHost(t *testing.T, mock *executor.MockExecutor) {
	t.Helper()
	// Preflight surface (mirrors PR-16/PR-17 tests).
	mock.NftTables["ip:nftban"] = true
	mock.Services["nftband.service"] = true
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.99.0\n")
	mock.RunResults["sh:-c:command -v nft >/dev/null 2>&1"] = executor.Result{ExitCode: 0}
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED\n")
	// DetectInstallOrigin probes — return "" from all to keep origin "".
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["rpm:-q:nftban"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban"] = executor.Result{ExitCode: 127}

	// Canonical rebuild entry — success, WITH the result contract the plane now consumes.
	applyRebuildShell(t, mock, "COMPLETE", 0)

	// Validator gate — success with a plausible JSON body.
	mock.RunResults["/usr/lib/nftban/bin/nftban-validate:--json"] = executor.Result{
		ExitCode: 0,
		Stdout:   `{"schema_version":"1.84.0","status":"protected"}`,
	}
}

// cmdTrace flattens mock.Commands into strings suitable for feeding into
// the auditRecordedCommands harness.
func cmdTrace(mock *executor.MockExecutor) []string {
	out := make([]string, 0, len(mock.Commands))
	for _, c := range mock.Commands {
		out = append(out, c.Name+" "+strings.Join(c.Args, " "))
	}
	return out
}

func writtenPaths(mock *executor.MockExecutor) []string {
	out := make([]string, 0, len(mock.WrittenFiles))
	for k := range mock.WrittenFiles {
		out = append(out, k)
	}
	return out
}

// T1 — Success path: everything passes, and the run still does NOT commit.
//
// ⛔ THIS TEST USED TO ASSERT THE DEFECT. It required rc == ExitCommitted(0) on a
// run that never evaluated convergence, which is exactly the contract v1.232.2
// removes — the test was pinning the bug in place. Renamed as well as re-asserted:
// leaving it called "_Exits0" would have left the old claim readable in the suite
// index even after the body changed.
func TestUpdateApply_AllPhasesPass_TerminatesAppliedUnverified(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc != state.ExitAppliedUnverified {
		t.Errorf("all-pass rc = %d; want ExitAppliedUnverified (%d) — preflight+rebuild+validator "+
			"passing is not a convergence proof", rc, state.ExitAppliedUnverified)
	}
	if sf.State != state.StateAppliedUnverified {
		t.Errorf("persisted state = %s; want %s", sf.State, state.StateAppliedUnverified)
	}
	if got := sf.State.ExitCode(); got != rc {
		t.Errorf("state.ExitCode() = %d but process exit = %d — state↔exit contradiction", got, rc)
	}

	// Contract audit: every recorded command must be in the whitelist.
	trace := cmdTrace(mock)
	if v := update.AuditRecordedCommands(trace); len(v) != 0 {
		t.Errorf("call-path contract violated on happy path:\n%s", strings.Join(v, "\n"))
	}
	if v := update.AuditWrittenFiles(writtenPaths(mock)); len(v) != 0 {
		t.Errorf("write-path contract violated on happy path:\n%s", strings.Join(v, "\n"))
	}
}

// T2 — Preflight failure blocks rebuild invocation AND maintains
// state↔exit agreement (PR-19 G3-U11 regression guard).
func TestUpdateApply_PreflightFail_DoesNotInvokeRebuild(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	// Break P-1 (authority_nftban): remove ip nftban table.
	delete(mock.NftTables, "ip:nftban")

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc == state.ExitCommitted {
		t.Error("preflight-fail path must not return ExitCommitted")
	}

	// PR-19 G3-U11: persisted state's derived exit must equal returned rc.
	if got := sf.State.ExitCode(); got != rc {
		t.Errorf("state↔exit contradiction: state.ExitCode() = %d, rc = %d", got, rc)
	}
	if sf.State != state.StateFailedNoFirewall {
		t.Errorf("persisted state = %s; want StateFailedNoFirewall for preflight-fail", sf.State)
	}

	// Rebuild must never have been invoked.
	for _, c := range mock.Commands {
		if c.Name == "nftban" && len(c.Args) >= 2 && c.Args[0] == "firewall" && c.Args[1] == "rebuild" {
			t.Error("rebuild invoked despite preflight failure — contract violated")
		}
	}
}

// T3 — Rebuild failure short-circuits before validator invocation.
func TestUpdateApply_RebuildFail_DoesNotInvokeValidator(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	applyRebuildShell(t, mock, "REGRESSION", 2)

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc != 2 {
		t.Errorf("rebuild-fail rc = %d; must propagate rebuild's exit (2) without reinterpretation", rc)
	}

	// Validator must never have been invoked — apply must not try to
	// "confirm" a failed rebuild. (Check by the absolute path we use now
	// so this regression guard survives the validator-path fix.)
	for _, c := range mock.Commands {
		if c.Name == "/usr/lib/nftban/bin/nftban-validate" {
			t.Error("validator invoked after rebuild failure — contract violated")
		}
	}
}

// T4 — G3-U8 TRUTH GATE: rebuild OK + validator fail → apply FAILS.
// This is the semantic the user called out explicitly: validator wins
// over rebuild. No success coercion, no error downgrading.
func TestUpdateApply_ValidatorFail_OverridesRebuildSuccess(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	// Rebuild succeeds, but validator rejects post-state.
	applyRebuildShell(t, mock, "COMPLETE", 0)
	mock.RunResults["/usr/lib/nftban/bin/nftban-validate:--json"] = executor.Result{
		ExitCode: 2, // validator exits 2 when state is "down"
		Stderr:   "post-state rejected",
	}

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc == state.ExitCommitted {
		t.Error("validator-fail path must NOT return ExitCommitted even though rebuild passed")
	}
	if rc != 2 {
		t.Errorf("validator-fail rc = %d; must propagate validator's exit (2) — truth gate discipline", rc)
	}
}

// T5 — Call-path purity under all failure branches.
func TestUpdateApply_CallPathPurity_AllBranches(t *testing.T) {
	branches := []struct {
		name  string
		setup func(*testing.T, *executor.MockExecutor)
	}{
		{"happy", func(_ *testing.T, m *executor.MockExecutor) {}},
		{"preflight-fail", func(_ *testing.T, m *executor.MockExecutor) {
			// Blocker #2 (code review): T5 must audit this branch too —
			// a non-whitelisted command or forbidden write slipping into
			// the preflight-fail path was previously uncaught by the
			// mechanical contract layer.
			delete(m.NftTables, "ip:nftban")
		}},
		{"rebuild-fail", func(t *testing.T, m *executor.MockExecutor) {
			applyRebuildShell(t, m, "REGRESSION", 2)
		}},
		{"validator-fail", func(_ *testing.T, m *executor.MockExecutor) {
			m.RunResults["nftban-validate:--json"] = executor.Result{ExitCode: 2}
		}},
	}
	for _, b := range branches {
		b := b
		t.Run(b.name, func(t *testing.T) {
			mock := executor.NewMockExecutor()
			seedHappyApplyHost(t, mock)
			b.setup(t, mock)
			cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
			sf := state.NewStateFile(cfg.stateDir)

			_ = runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())

			trace := cmdTrace(mock)
			if v := update.AuditRecordedCommands(trace); len(v) != 0 {
				t.Errorf("call-path contract violated on %s branch:\n%s", b.name, strings.Join(v, "\n"))
			}
			if v := update.AuditWrittenFiles(writtenPaths(mock)); len(v) != 0 {
				t.Errorf("write-path contract violated on %s branch:\n%s", b.name, strings.Join(v, "\n"))
			}
		})
	}
}

// T7 — G3-U7 recovery delegation: on rebuild failure, apply must NOT
// issue any additional mutation commands. Recovery belongs to rebuild
// (firewall_rebuild in cli/lib/nftban/cli/cmd_firewall.sh calls into
// nftban_rebuild_recovery.sh itself). Apply must be a silent
// propagator of rebuild's exit code.
func TestUpdateApply_RebuildFail_NoRetryNoRecovery(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	applyRebuildShell(t, mock, "REGRESSION", 2)

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	_ = runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())

	// Count how many times rebuild was invoked — must be EXACTLY 1.
	var rebuildCount int
	for _, c := range mock.Commands {
		if c.Name == "nftban" && len(c.Args) >= 2 && c.Args[0] == "firewall" && c.Args[1] == "rebuild" {
			rebuildCount++
		}
	}
	if rebuildCount != 1 {
		t.Errorf("rebuild invoked %d times; apply must NOT retry (firewall_rebuild owns retry per v1.96)", rebuildCount)
	}

	// No recovery-flavored commands (apply doesn't OWN recovery).
	for _, c := range mock.Commands {
		cmd := c.Name + " " + strings.Join(c.Args, " ")
		for _, forbidden := range []string{
			"firewall restore", "firewall reset", "health fix",
			"rebuild-recovery", "restore-snapshot",
		} {
			if strings.Contains(cmd, forbidden) {
				t.Errorf("apply invoked recovery-flavored command %q — must delegate to rebuild", cmd)
			}
		}
	}
}

// T8 — G3-U8 truth-gate discipline: apply must trust validator's EXIT
// CODE and must NOT parse validator JSON to derive a different outcome.
// This locks behaviour against a common regression class where a later
// change "helpfully" inspects the JSON body and overrides the exit.
func TestUpdateApply_DoesNotReinterpretValidatorOutput(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	// Exit says FAIL (2), but JSON says "protected". Apply must honour
	// the exit code, not the body.
	mock.RunResults["/usr/lib/nftban/bin/nftban-validate:--json"] = executor.Result{
		ExitCode: 2,
		Stdout:   `{"schema_version":"1.84.0","status":"protected"}`,
	}

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc == state.ExitCommitted {
		t.Error("apply must not coerce exit=2 into success even when JSON body says 'protected'")
	}
	if rc != 2 {
		t.Errorf("rc = %d; must equal validator's exit (2) — no reinterpretation", rc)
	}
}

// T9 — blocker #1 mapping: validator rc=1 → StateDegraded.
// Verifies stateForValidatorExit(1) matches the persisted transition
// AND that State.ExitCode() aligns with the returned process exit
// (state↔process truth must not contradict).
func TestUpdateApply_ValidatorExit1_TransitionsToStateDegraded(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	mock.RunResults["/usr/lib/nftban/bin/nftban-validate:--json"] = executor.Result{ExitCode: 1}

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc != 1 {
		t.Errorf("process exit = %d; want 1 (validator's exit)", rc)
	}
	if sf.State != state.StateDegraded {
		t.Errorf("persisted state = %s; want StateDegraded for validator rc=1", sf.State)
	}
	if got := sf.State.ExitCode(); got != rc {
		t.Errorf("state.ExitCode() = %d but process exit = %d — state↔exit contradiction", got, rc)
	}
}

// T10 — blocker #1 mapping: validator rc=2 → StateFailedRebuild.
// Verifies the stronger validator failure is NOT collapsed into the
// weaker StateDegraded.
func TestUpdateApply_ValidatorExit2_TransitionsToStateFailedRebuild(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	mock.RunResults["/usr/lib/nftban/bin/nftban-validate:--json"] = executor.Result{ExitCode: 2}

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc != 2 {
		t.Errorf("process exit = %d; want 2 (validator's exit)", rc)
	}
	if sf.State != state.StateFailedRebuild {
		t.Errorf("persisted state = %s; want StateFailedRebuild for validator rc=2 (truth-gate discipline)", sf.State)
	}
	if got := sf.State.ExitCode(); got != rc {
		t.Errorf("state.ExitCode() = %d but process exit = %d — state↔exit contradiction", got, rc)
	}
}

// T11 — stateForValidatorExit pure helper, exhaustive small-range check.
func TestStateForValidatorExit_Mapping(t *testing.T) {
	cases := []struct {
		rc   int
		want state.InstallState
	}{
		{1, state.StateDegraded},
		{2, state.StateFailedRebuild},
		{3, state.StateFailedRebuild},   // validator binary crash → failed-rebuild class
		{127, state.StateFailedRebuild}, // command-not-found → failed-rebuild class
	}
	for _, c := range cases {
		got := stateForValidatorExit(c.rc)
		if got != c.want {
			t.Errorf("stateForValidatorExit(%d) = %s; want %s", c.rc, got, c.want)
		}
	}
}

// T6 — G3-U5 .conf.local byte-preservation.
// Apply must never write to any *.conf.local path, regardless of outcome.
func TestUpdateApply_NeverTouchesConfLocal(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	// Pre-seed a .conf.local so the post-run audit can observe it.
	preContent := []byte("OPERATOR_EDITED=1\n")
	mock.Files["/etc/nftban/nftban.conf.local"] = append([]byte{}, preContent...)

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	_ = runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())

	// Byte hash must match — mock.WrittenFiles only captures writes via
	// the mock's WriteFileAtomic path; apply never writes through it.
	if got, ok := mock.WrittenFiles["/etc/nftban/nftban.conf.local"]; ok {
		t.Errorf("G3-U5 VIOLATION — apply wrote to .conf.local: %q", got)
	}
	// Post-content in Files must still equal pre-content.
	if got, ok := mock.Files["/etc/nftban/nftban.conf.local"]; !ok || string(got) != string(preContent) {
		t.Errorf("G3-U5 VIOLATION — .conf.local bytes changed: pre=%q post=%q", preContent, got)
	}
}
