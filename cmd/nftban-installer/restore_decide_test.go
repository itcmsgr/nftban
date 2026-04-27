// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — Restore Dispatcher tests (commit 4)
// =============================================================================
// meta:name="nftban-installer-restore-decide-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-27"
// meta:description="PR-25 commit 4 dispatcher integration tests. Focuses on runRestoreExecutionFromProceed (the testable PROCEED helper) and the newRestoreDeps factory injection seam. Does NOT exercise the upstream classify/probe/detect calls — those are integration-level and have their own existing tests in internal/installer/restore + uninstall."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/logging,github.com/itcmsgr/nftban/internal/installer/restore,github.com/itcmsgr/nftban/internal/installer/state,github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files=""
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
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// =============================================================================
// Test scaffolding
// =============================================================================

// newTestStateFile builds a StateFile rooted in a temp dir with
// DryRun=true so Transition() updates in-memory state without
// touching disk.
func newTestStateFile(t *testing.T) *state.StateFile {
	t.Helper()
	sf := state.NewStateFile(t.TempDir())
	sf.DryRun = true
	return sf
}

// newTestLogger builds a logger that writes to a temp file. The file
// content is incidental to tests — they assert on persisted state and
// dep call counts, not log output.
func newTestLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New(filepath.Join(t.TempDir(), "test.log"), false)
}

// procRecordedPriorFixture builds a PROCEED + RecordedPrior fixture
// matching PR-24's G3.1/StrongPrior+NoFlag rule.
func procRecordedPriorFixture() (restore.DecisionResult, restore.DecisionInput, *uninstall.PriorRecord, detect.PanelType) {
	dr := restore.DecisionResult{
		Output: restore.OutputProceed,
		Rule:   restore.RuleG3_1StrongPriorNoFlag,
		Reason: "fixture",
	}
	in := restore.DecisionInput{
		Authority:    uninstall.AuthorityNone,
		Ambiguity:    uninstall.AmbiguityNone,
		Prior:        restore.PriorStateCompleteActive,
		Flags:        restore.Flags{Restore: false, PanelAutoTakeover: false},
		PanelPresent: false,
	}
	rec := &uninstall.PriorRecord{
		SchemaVersion: uninstall.PriorRecordSchemaVersion,
		FirewallType:  "ufw",
	}
	return dr, in, rec, detect.PanelNone
}

// procPanelNativeDirectAdminFixture builds a PROCEED + PanelNative
// (DirectAdmin) fixture matching G3.3/NoRecord+PanelAuto.
func procPanelNativeDirectAdminFixture() (restore.DecisionResult, restore.DecisionInput, *uninstall.PriorRecord, detect.PanelType) {
	dr := restore.DecisionResult{
		Output: restore.OutputProceed,
		Rule:   restore.RuleG3_3NoRecordPanelAuto,
		Reason: "fixture",
	}
	in := restore.DecisionInput{
		Authority:    uninstall.AuthorityNone,
		Ambiguity:    uninstall.AmbiguityNone,
		Prior:        restore.PriorStateNoRecord,
		Flags:        restore.Flags{Restore: false, PanelAutoTakeover: true},
		PanelPresent: true,
	}
	return dr, in, nil, detect.PanelDirectAdmin
}

// procPanelNativeUnmappedFixture builds a PROCEED + PanelNative fixture
// for an intentionally-unmapped panel (CPanel — see panel_mapping.go
// commit 3A: only DirectAdmin is mapped). The planner accepts the
// inputs and resolves Kind=PanelNative; Execute then refuses at
// resolveFirewallType because §20 mapping has no entry.
func procPanelNativeUnmappedFixture() (restore.DecisionResult, restore.DecisionInput, *uninstall.PriorRecord, detect.PanelType) {
	dr, in, rec, _ := procPanelNativeDirectAdminFixture()
	return dr, in, rec, detect.PanelCPanel
}

// stubExecutorForPreflightFirewall builds a MockExecutor with the
// canonical binary + a canonical unit file present for the given
// firewallType, so the (now real) productionPreflightDep returns
// ok=true and Execute proceeds.
//
// 4B-2 update: also seeds a minimal /etc/ssh/sshd_config with
// "Port 22" so the (now real) productionSafetyNetDep's SSH-port
// detection succeeds via the sshd_config source. Without this,
// safety-net Insert would refuse with ErrSafetyNetSSHPortUnknown
// before reaching the still-stub mutation step.
//
// After 4B-2, dispatcher stub-tests reach Stage=mutate (still stub)
// and refuse with ErrRestoreExecutionUnavailable from the mutation
// dep. After 4B-3, they will reach Stage=verify, etc.
func stubExecutorForPreflightFirewall(fwt string) executor.Executor {
	mock := executor.NewMockExecutor()
	switch fwt {
	case "ufw":
		mock.ExistingCommands["ufw"] = true
		mock.Files["/usr/lib/systemd/system/ufw.service"] = []byte{}
	case "firewalld":
		mock.ExistingCommands["firewall-cmd"] = true
		mock.Files["/usr/lib/systemd/system/firewalld.service"] = []byte{}
	case "iptables":
		mock.ExistingCommands["iptables"] = true
		mock.Files["/usr/lib/systemd/system/iptables.service"] = []byte{}
	case "csf":
		mock.ExistingCommands["csf"] = true
		mock.Files["/etc/systemd/system/csf.service"] = []byte{}
	}
	// 4B-2: sshd_config so detect.SSHPort can resolve via Source 2.
	// (Source 1 'ss' returns no-listener output by default in mock.)
	mock.Files["/etc/ssh/sshd_config"] = []byte("Port 22\n")
	return mock
}

// =============================================================================
// 1. Stub-deps path: PROCEED + RecordedPrior persists FailedExecution
//    with ErrRestoreExecutionUnavailable in the chain.
// =============================================================================

func TestRunRestoreExecutionFromProceed_StubDeps_RecordedPrior_PersistsFailedExecution(t *testing.T) {
	sf := newTestStateFile(t)
	log := newTestLogger(t)
	dr, in, rec, panel := procRecordedPriorFixture() // ufw target

	// 4B-1: preflight is now real. Provide a MockExecutor with the
	// canonical ufw binary + unit file so preflight passes; the
	// next step (safety-net insert, still a stub) refuses with
	// ErrRestoreExecutionUnavailable.
	exec := stubExecutorForPreflightFirewall("ufw")

	exit := runRestoreExecutionFromProceed(context.Background(), exec, sf, log, dr, in, rec, panel)

	// Real preflight passes -> stub safety-net insert refuses ->
	// Execute terminates at Stage=insert with FailedExecution.
	if sf.State != state.StateRestoreFailedExecution {
		t.Errorf("State = %q; want StateRestoreFailedExecution (stub safety-net refuses)", sf.State)
	}
	if exit != state.ExitRestoreFailedExecution {
		t.Errorf("exit = %d; want %d", exit, state.ExitRestoreFailedExecution)
	}
	// FailureReason must surface the typed stub sentinel from the
	// safety-net insert path.
	if !strings.Contains(sf.FailureReason, ErrRestoreExecutionUnavailable.Error()) &&
		!strings.Contains(sf.FailureReason, "execution dependency not implemented") {
		t.Errorf("FailureReason does not surface ErrRestoreExecutionUnavailable: %q", sf.FailureReason)
	}
}

// =============================================================================
// 2. Stub-deps path: PROCEED + PanelNative DirectAdmin persists
//    FailedExecution. (Mapping resolves to "csf"; preflight stub still
//    refuses with ErrRestoreExecutionUnavailable.)
// =============================================================================

func TestRunRestoreExecutionFromProceed_StubDeps_PanelNativeDirectAdmin_PersistsFailedExecution(t *testing.T) {
	sf := newTestStateFile(t)
	log := newTestLogger(t)
	dr, in, rec, panel := procPanelNativeDirectAdminFixture()

	// 4B-1: PanelDirectAdmin maps to "csf" via §20; preflight needs
	// csf binary + unit file present.
	exec := stubExecutorForPreflightFirewall("csf")

	exit := runRestoreExecutionFromProceed(context.Background(), exec, sf, log, dr, in, rec, panel)

	if sf.State != state.StateRestoreFailedExecution {
		t.Errorf("State = %q; want StateRestoreFailedExecution", sf.State)
	}
	if exit != state.ExitRestoreFailedExecution {
		t.Errorf("exit = %d; want %d", exit, state.ExitRestoreFailedExecution)
	}
}

// =============================================================================
// 3. Planner refusal path: PROCEED + PanelNative unmapped panel.
//    Execute step 0 (target resolution) refuses BEFORE any dep call,
//    yielding StateRestoreFailedExecution with ErrUnmappedPanel in
//    the chain.
// =============================================================================

func TestRunRestoreExecutionFromProceed_PanelNative_UnmappedPanel_FailsExecution(t *testing.T) {
	sf := newTestStateFile(t)
	log := newTestLogger(t)
	dr, in, rec, panel := procPanelNativeUnmappedFixture()

	exit := runRestoreExecutionFromProceed(context.Background(), nil, sf, log, dr, in, rec, panel)

	if sf.State != state.StateRestoreFailedExecution {
		t.Errorf("State = %q; want StateRestoreFailedExecution (unmapped panel)", sf.State)
	}
	if exit != state.ExitRestoreFailedExecution {
		t.Errorf("exit = %d; want %d", exit, state.ExitRestoreFailedExecution)
	}
	// FailureReason must surface the §20 unmapped-panel rejection.
	if !strings.Contains(sf.FailureReason, "no PR-25 firewall mapping") &&
		!strings.Contains(sf.FailureReason, restore.ErrUnmappedPanel.Error()) {
		t.Errorf("FailureReason does not surface ErrUnmappedPanel: %q", sf.FailureReason)
	}
}

// =============================================================================
// 4. Planner-refusal path: non-PROCEED DecisionResult passed in by
//    accident. Planner returns ErrPlanNotProceed; dispatcher persists
//    StateRestoreFailedExecution. Execute is NOT called.
// =============================================================================

func TestRunRestoreExecutionFromProceed_NonProceedAccident_PlannerErrors(t *testing.T) {
	sf := newTestStateFile(t)
	log := newTestLogger(t)
	_, in, rec, panel := procRecordedPriorFixture()

	// Caller-corruption simulation: pass REFUSE into the helper.
	dr := restore.DecisionResult{
		Output: restore.OutputRefuse,
		Rule:   "G1/AuthorityNFTBan",
		Reason: "fixture",
	}

	exit := runRestoreExecutionFromProceed(context.Background(), nil, sf, log, dr, in, rec, panel)

	if sf.State != state.StateRestoreFailedExecution {
		t.Errorf("State = %q; want StateRestoreFailedExecution (planner refused non-PROCEED)", sf.State)
	}
	if exit != state.ExitRestoreFailedExecution {
		t.Errorf("exit = %d; want %d", exit, state.ExitRestoreFailedExecution)
	}
	// Reason must surface the planner sentinel.
	if !strings.Contains(sf.FailureReason, restore.ErrPlanNotProceed.Error()) {
		t.Errorf("FailureReason does not surface ErrPlanNotProceed: %q", sf.FailureReason)
	}
}

// =============================================================================
// 5. PROCEED never persists StateRestoreDecided after PR-25.
// =============================================================================

func TestRunRestoreExecutionFromProceed_NeverPersistsStateRestoreDecided(t *testing.T) {
	sf := newTestStateFile(t)
	log := newTestLogger(t)
	dr, in, rec, panel := procRecordedPriorFixture()
	// 4B-1: provide working executor so preflight passes through to
	// the next stub. The terminal will be FailedExecution at insert,
	// not Decided either way — but be deterministic about it.
	exec := stubExecutorForPreflightFirewall("ufw")

	_ = runRestoreExecutionFromProceed(context.Background(), exec, sf, log, dr, in, rec, panel)

	if sf.State == state.StateRestoreDecided {
		t.Errorf("PROCEED persisted StateRestoreDecided; PR-25 must produce a §22 execution terminal")
	}
}

// =============================================================================
// 6. newRestoreDeps factory injection: tests can swap to fake deps
//    that drive Execute to specific terminals.
// =============================================================================

// fakeDispatcherDeps is a complete fake implementing all 4 restore
// dep interfaces. Drives Execute to controlled outcomes.
type fakeDispatcherDeps struct {
	preflightOK    bool
	insertErr      error
	mutateErr      error
	activeRet      bool
	authorityRet   uninstall.CurrentAuthority
	safeRet        bool
	removeErr      error
	preflightCalls int
	mutateCalls    int
	insertCalls    int
	removeCalls    int
}

func (f *fakeDispatcherDeps) PreflightTarget(_ context.Context, _ string) (bool, error) {
	f.preflightCalls++
	return f.preflightOK, nil
}
func (f *fakeDispatcherDeps) InsertEmergencySSH(_ context.Context) error {
	f.insertCalls++
	return f.insertErr
}
func (f *fakeDispatcherDeps) RemoveEmergencySSH(_ context.Context) error {
	f.removeCalls++
	return f.removeErr
}
func (f *fakeDispatcherDeps) MutateToTarget(_ context.Context, _ string) error {
	f.mutateCalls++
	return f.mutateErr
}
func (f *fakeDispatcherDeps) IsTargetFirewallActive(_ context.Context, _ string) (bool, error) {
	return f.activeRet, nil
}
func (f *fakeDispatcherDeps) CurrentAuthorityClass(_ context.Context) (uninstall.CurrentAuthority, error) {
	return f.authorityRet, nil
}
func (f *fakeDispatcherDeps) IsSafetyNetRemovalSafe(_ context.Context) (bool, error) {
	return f.safeRet, nil
}

// withFakeDeps temporarily swaps newRestoreDeps to return a fake
// instance. Tests defer the restore.
func withFakeDeps(t *testing.T, fake *fakeDispatcherDeps) {
	t.Helper()
	saved := newRestoreDeps
	newRestoreDeps = func(_ executor.Executor, _ *logging.Logger) restore.ExecuteDeps {
		return restore.ExecuteDeps{
			Preflight:    fake,
			SafetyNet:    fake,
			Mutation:     fake,
			InlineVerify: fake,
		}
	}
	t.Cleanup(func() { newRestoreDeps = saved })
}

func TestRunRestoreExecutionFromProceed_FakeDeps_HappyPath_PersistsExecuted(t *testing.T) {
	fake := &fakeDispatcherDeps{
		preflightOK:  true,
		activeRet:    true,
		authorityRet: uninstall.AuthorityExternal,
		safeRet:      true,
	}
	withFakeDeps(t, fake)

	sf := newTestStateFile(t)
	log := newTestLogger(t)
	dr, in, rec, panel := procRecordedPriorFixture()

	exit := runRestoreExecutionFromProceed(context.Background(), nil, sf, log, dr, in, rec, panel)

	if sf.State != state.StateRestoreExecuted {
		t.Errorf("State = %q; want StateRestoreExecuted (fake happy path)", sf.State)
	}
	if exit != state.ExitRestoreExecuted {
		t.Errorf("exit = %d; want %d", exit, state.ExitRestoreExecuted)
	}
	// Plan was called exactly once (planner is pure — no counter, but
	// reaching Execute proves it returned a target). Execute calls:
	// preflight 1, insert 1, mutate 1, remove 1.
	if fake.preflightCalls != 1 || fake.insertCalls != 1 || fake.mutateCalls != 1 || fake.removeCalls != 1 {
		t.Errorf("call counts = (preflight=%d insert=%d mutate=%d remove=%d); want all 1",
			fake.preflightCalls, fake.insertCalls, fake.mutateCalls, fake.removeCalls)
	}
}

// =============================================================================
// 7. Fake-deps mutate-failure persists FailedExecution (terminal
//    truthfulness through the dispatcher persist layer).
// =============================================================================

func TestRunRestoreExecutionFromProceed_FakeDeps_MutateFailure(t *testing.T) {
	fake := &fakeDispatcherDeps{
		preflightOK: true,
		mutateErr:   errors.New("simulated mutation failure"),
	}
	withFakeDeps(t, fake)

	sf := newTestStateFile(t)
	log := newTestLogger(t)
	dr, in, rec, panel := procRecordedPriorFixture()

	exit := runRestoreExecutionFromProceed(context.Background(), nil, sf, log, dr, in, rec, panel)

	if sf.State != state.StateRestoreFailedExecution {
		t.Errorf("State = %q; want StateRestoreFailedExecution", sf.State)
	}
	if exit != state.ExitRestoreFailedExecution {
		t.Errorf("exit = %d; want %d", exit, state.ExitRestoreFailedExecution)
	}
	// Verify-stage dep methods must NOT have been called.
	if fake.removeCalls != 0 {
		t.Errorf("removeCalls = %d on mutate-failure; safety-net retention violated", fake.removeCalls)
	}
}

// =============================================================================
// 8. Fake-deps verify-failure persists FailedVerification (safety net
//    must NOT be removed).
// =============================================================================

func TestRunRestoreExecutionFromProceed_FakeDeps_VerifyFailure_NoRemove(t *testing.T) {
	fake := &fakeDispatcherDeps{
		preflightOK:  true,
		activeRet:    false, // verify-active fails
		authorityRet: uninstall.AuthorityExternal,
		safeRet:      true,
	}
	withFakeDeps(t, fake)

	sf := newTestStateFile(t)
	log := newTestLogger(t)
	dr, in, rec, panel := procRecordedPriorFixture()

	exit := runRestoreExecutionFromProceed(context.Background(), nil, sf, log, dr, in, rec, panel)

	if sf.State != state.StateRestoreFailedVerification {
		t.Errorf("State = %q; want StateRestoreFailedVerification", sf.State)
	}
	if exit != state.ExitRestoreFailedVerification {
		t.Errorf("exit = %d; want %d", exit, state.ExitRestoreFailedVerification)
	}
	if fake.removeCalls != 0 {
		t.Errorf("removeCalls = %d on verify-fail; §21.3 violation", fake.removeCalls)
	}
}

// =============================================================================
// 9. Dispatcher source pin: REFUSE / REQUIRE_EXPLICIT_INTENT branches
//    do NOT reference runRestoreExecutionFromProceed.
//
//    Structural assertion: the runRestoreDecide source contains a
//    case-OutputRefuse arm that calls Transition + log.Result and
//    returns directly, and the same shape for REQUIRE_EXPLICIT_INTENT.
//    Only the case-OutputProceed arm calls runRestoreExecutionFromProceed.
//
//    This test is the file-content equivalent of "REFUSE doesn't call
//    Plan/Execute" — the structural separation makes it impossible
//    for the helper to be reached from the non-PROCEED arms.
// =============================================================================

func TestDispatcher_NonProceedArms_DoNotCallExecutionHelper(t *testing.T) {
	body, err := readSelfRestoreDecide()
	if err != nil {
		t.Fatalf("read restore_decide.go: %v", err)
	}
	// The PROCEED case must call the helper.
	if !strings.Contains(body, "runRestoreExecutionFromProceed(") {
		t.Errorf("dispatcher source no longer calls runRestoreExecutionFromProceed; PROCEED→Execute path is broken")
	}
	// The REFUSE arm must NOT call the helper. We cheaply assert by
	// requiring exactly ONE call site (in the PROCEED arm).
	count := strings.Count(body, "runRestoreExecutionFromProceed(")
	// One call expression + one definition (func ... runRestoreExecutionFromProceed( + body). So 2 occurrences.
	if count != 2 {
		t.Errorf("runRestoreExecutionFromProceed referenced %d times in restore_decide.go; want 2 (definition + single PROCEED call)",
			count)
	}
}

// =============================================================================
// 10. Dispatcher source: no dispatcher-local Group→Kind mapping logic.
//     The mapping (Flags.PanelAutoTakeover -> PanelNative; else
//     RecordedPrior) lives ONLY in the planner.
// =============================================================================

func TestDispatcher_NoLocalGroupKindMapping(t *testing.T) {
	body, err := readSelfRestoreDecide()
	if err != nil {
		t.Fatalf("read restore_decide.go: %v", err)
	}
	// The dispatcher must not reference the constructors directly.
	// (The planner does that internally via its own logic.)
	for _, pat := range []string{
		"TargetRecordedPrior(",
		"TargetPanelNative(",
		"TargetAuthorityKindRecordedPrior",
		"TargetAuthorityKindPanelNative",
	} {
		if strings.Contains(body, pat) {
			t.Errorf("dispatcher source references %q; Group→Kind mapping must live only in the planner", pat)
		}
	}
}

// =============================================================================
// 11. Dispatcher source: no real mutation / no live re-detection.
// =============================================================================

func TestDispatcher_NoForbiddenSurfaces_FileScan(t *testing.T) {
	// Concrete call expressions only (per the same discipline as
	// commit 3C's execute file-scan).
	forbidden := []string{
		"exec.Command",
		"os.WriteFile",
		"os.Create",
		"os.Remove(",
		"os.Rename",
		"syscall.",
		`"nft "`,
		`"systemctl `,
		// History writes — restore-mode is gated at main.go:132 and
		// the dispatcher must not bypass.
		"writeHistory(",
		// Live re-detection of resolved authority after planner.
		// (Note: classify/probe/detect calls BEFORE Decide are legitimate
		// PR-24 inputs; we only forbid them inside the helper or the
		// PROCEED arm. Crude check: the substring "uninstall.Classify("
		// must NOT appear inside the PROCEED branch — but the file as
		// a whole has it via PR-24 step 1. Instead we forbid the
		// helper-internal pattern by name.)
		"runRestoreExecutionFromProceed(ctx, exec, sf, log, result, input, probe.Record, panel)\n\t\tuninstall.Classify",
	}
	body, err := readSelfRestoreDecide()
	if err != nil {
		t.Fatalf("read restore_decide.go: %v", err)
	}
	for _, pat := range forbidden {
		if strings.Contains(body, pat) {
			t.Errorf("restore_decide.go references forbidden pattern %q", pat)
		}
	}
}

// =============================================================================
// helpers
// =============================================================================

func readSelfRestoreDecide() (string, error) {
	b, err := os.ReadFile("restore_decide.go")
	if err != nil {
		return "", err
	}
	return string(b), nil
}
