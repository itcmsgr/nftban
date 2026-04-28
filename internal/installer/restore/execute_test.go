// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Execute orchestration tests (PR-25 §23)
// =============================================================================
// meta:name="restore_execute_test"
// meta:type="test"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3C tests: §23 ordering, refusal-before-mutation, terminal-state truthfulness, safety-net retention on verify-fail, no live re-detection inside Execute."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/state,github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package restore

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// =============================================================================
// Test scaffolding — fakes that record every call into a single
// shared trace slice, so ordering tests don't have to correlate
// counts across multiple structs.
// =============================================================================

type traceFakeDeps struct {
	trace []string

	// Per-step injected outcomes
	preflightOK    bool
	preflightErr   error
	insertErr      error
	mutateErr      error
	authorityRet   uninstall.CurrentAuthority
	authorityErr   error
	activeRet      bool
	activeErr      error
	safeRet        bool
	safeErr        error
	removeErr      error

	// Last firewallType seen by mutation/preflight, for Q4 verification
	lastFirewallTypePreflight string
	lastFirewallTypeMutate    string
	lastFirewallTypeVerify    string
}

func newTraceDeps() *traceFakeDeps {
	return &traceFakeDeps{
		preflightOK:  true,
		authorityRet: uninstall.AuthorityExternal,
		activeRet:    true,
		safeRet:      true,
	}
}

// PreflightDep
func (f *traceFakeDeps) PreflightTarget(_ context.Context, fwt string) (bool, error) {
	f.trace = append(f.trace, "preflight")
	f.lastFirewallTypePreflight = fwt
	return f.preflightOK, f.preflightErr
}

// SafetyNetDep
func (f *traceFakeDeps) InsertEmergencySSH(_ context.Context) error {
	f.trace = append(f.trace, "insert")
	return f.insertErr
}

func (f *traceFakeDeps) RemoveEmergencySSH(_ context.Context) error {
	f.trace = append(f.trace, "remove")
	return f.removeErr
}

// MutationDep
func (f *traceFakeDeps) MutateToTarget(_ context.Context, fwt string) error {
	f.trace = append(f.trace, "mutate")
	f.lastFirewallTypeMutate = fwt
	return f.mutateErr
}

// InlineVerifyDep
func (f *traceFakeDeps) IsTargetFirewallActive(_ context.Context, fwt string) (bool, error) {
	f.trace = append(f.trace, "verify-active")
	f.lastFirewallTypeVerify = fwt
	return f.activeRet, f.activeErr
}

func (f *traceFakeDeps) CurrentAuthorityClass(_ context.Context) (uninstall.CurrentAuthority, error) {
	f.trace = append(f.trace, "verify-authority")
	return f.authorityRet, f.authorityErr
}

func (f *traceFakeDeps) IsSafetyNetRemovalSafe(_ context.Context) (bool, error) {
	f.trace = append(f.trace, "verify-safe")
	return f.safeRet, f.safeErr
}

func (f *traceFakeDeps) deps() ExecuteDeps {
	return ExecuteDeps{
		Preflight:    f,
		SafetyNet:    f,
		Mutation:     f,
		InlineVerify: f,
	}
}

// =============================================================================
// 1. Zero-value TargetAuthority refuses BEFORE preflight/safety-net/mutation
// =============================================================================

func TestExecute_ZeroValue_RefusesBeforeAnyDepCall(t *testing.T) {
	f := newTraceDeps()
	res := Execute(context.Background(), TargetAuthority{}, f.deps())

	if !errors.Is(res.Err, ErrExecuteRefusedNoneTarget) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedExecution {
		t.Errorf("Terminal = %q; want StateRestoreFailedExecution", res.Terminal)
	}
	if len(f.trace) != 0 {
		t.Errorf("zero-value Execute called deps: %v (must refuse before any call)", f.trace)
	}
}

// =============================================================================
// 2. TargetNone() refuses BEFORE preflight/safety-net/mutation
// =============================================================================

func TestExecute_TargetNone_RefusesBeforeAnyDepCall(t *testing.T) {
	f := newTraceDeps()
	res := Execute(context.Background(), TargetNone(), f.deps())

	if !errors.Is(res.Err, ErrExecuteRefusedNoneTarget) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedExecution {
		t.Errorf("Terminal = %q; want StateRestoreFailedExecution", res.Terminal)
	}
	if len(f.trace) != 0 {
		t.Errorf("TargetNone() Execute called deps: %v", f.trace)
	}
}

// =============================================================================
// 3. Preflight failure stops immediately (no safety-net, no mutation)
// =============================================================================

func TestExecute_PreflightLogicalRefusal_StopsImmediately(t *testing.T) {
	f := newTraceDeps()
	f.preflightOK = false

	ta, _ := TargetRecordedPrior("ufw")
	res := Execute(context.Background(), ta, f.deps())

	if !errors.Is(res.Err, ErrExecutePreflightRefused) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedExecution {
		t.Errorf("Terminal = %q; want StateRestoreFailedExecution", res.Terminal)
	}
	if res.Stage != StagePreflight {
		t.Errorf("Stage = %q; want %q", res.Stage, StagePreflight)
	}
	wantTrace := []string{"preflight"}
	if !traceEqual(f.trace, wantTrace) {
		t.Errorf("trace = %v; want %v (preflight refusal must stop before insert/mutate)", f.trace, wantTrace)
	}
}

func TestExecute_PreflightDepError_StopsImmediately(t *testing.T) {
	f := newTraceDeps()
	f.preflightErr = errors.New("simulated preflight failure")

	ta, _ := TargetRecordedPrior("ufw")
	res := Execute(context.Background(), ta, f.deps())

	if res.Terminal != state.StateRestoreFailedExecution {
		t.Errorf("Terminal = %q; want StateRestoreFailedExecution", res.Terminal)
	}
	if res.Stage != StagePreflight {
		t.Errorf("Stage = %q; want %q", res.Stage, StagePreflight)
	}
	if !traceEqual(f.trace, []string{"preflight"}) {
		t.Errorf("trace = %v; want [preflight]", f.trace)
	}
}

// =============================================================================
// 4. Safety-net insert failure stops BEFORE target mutation
// =============================================================================

func TestExecute_InsertFailure_StopsBeforeMutate(t *testing.T) {
	f := newTraceDeps()
	f.insertErr = errors.New("simulated insert failure")

	ta, _ := TargetRecordedPrior("ufw")
	res := Execute(context.Background(), ta, f.deps())

	if !errors.Is(res.Err, ErrExecuteInsertFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedExecution {
		t.Errorf("Terminal = %q; want StateRestoreFailedExecution", res.Terminal)
	}
	if res.Stage != StageInsert {
		t.Errorf("Stage = %q; want %q", res.Stage, StageInsert)
	}
	wantTrace := []string{"preflight", "insert"}
	if !traceEqual(f.trace, wantTrace) {
		t.Errorf("trace = %v; want %v (insert failure must stop before mutate)", f.trace, wantTrace)
	}
}

// =============================================================================
// 5. Target mutation failure → StateRestoreFailedExecution, safety-net retained
// =============================================================================

func TestExecute_MutateFailure_FailedExecution_SafetyNetRetained(t *testing.T) {
	f := newTraceDeps()
	f.mutateErr = errors.New("simulated mutation failure")

	ta, _ := TargetRecordedPrior("firewalld")
	res := Execute(context.Background(), ta, f.deps())

	if !errors.Is(res.Err, ErrExecuteMutateFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedExecution {
		t.Errorf("Terminal = %q; want StateRestoreFailedExecution", res.Terminal)
	}
	if res.Stage != StageMutate {
		t.Errorf("Stage = %q; want %q", res.Stage, StageMutate)
	}
	// Trace must be: preflight, insert, mutate. NO verify, NO remove.
	wantTrace := []string{"preflight", "insert", "mutate"}
	if !traceEqual(f.trace, wantTrace) {
		t.Errorf("trace = %v; want %v (mutate failure: no verify, no remove)", f.trace, wantTrace)
	}
	// Belt-and-braces: ensure "remove" never appears in the trace.
	for _, c := range f.trace {
		if c == "remove" {
			t.Errorf("remove was called after mutate failure — safety-net retention violated")
		}
	}
}

// =============================================================================
// 6. Inline verification logical fail → FailedVerification, NO removal
// =============================================================================

func TestExecute_VerifyAssertionFails_NoRemoval(t *testing.T) {
	f := newTraceDeps()
	f.activeRet = false // assertion 1 fails

	ta, _ := TargetRecordedPrior("ufw")
	res := Execute(context.Background(), ta, f.deps())

	if !errors.Is(res.Err, ErrExecuteVerifyFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedVerification {
		t.Errorf("Terminal = %q; want StateRestoreFailedVerification", res.Terminal)
	}
	if res.Stage != StageVerify {
		t.Errorf("Stage = %q; want %q", res.Stage, StageVerify)
	}
	// No remove.
	for _, c := range f.trace {
		if c == "remove" {
			t.Errorf("remove called after verify-fail — §21.3 violation. trace=%v", f.trace)
		}
	}
	if res.VerifyResult.SafeToRemove {
		t.Errorf("VerifyResult.SafeToRemove = true on verify-fail; want false")
	}
}

func TestExecute_VerifyDepError_NoRemoval(t *testing.T) {
	f := newTraceDeps()
	f.authorityErr = errors.New("simulated classify failure")

	ta, _ := TargetRecordedPrior("ufw")
	res := Execute(context.Background(), ta, f.deps())

	if !errors.Is(res.Err, ErrExecuteVerifyFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedVerification {
		t.Errorf("Terminal = %q; want StateRestoreFailedVerification", res.Terminal)
	}
	for _, c := range f.trace {
		if c == "remove" {
			t.Errorf("remove called after verify-dep-error — §21.3 violation. trace=%v", f.trace)
		}
	}
}

// =============================================================================
// 7. Safety-net removal failure → non-success terminal (do not report success)
// =============================================================================

func TestExecute_RemoveFailure_NonSuccessTerminal(t *testing.T) {
	f := newTraceDeps()
	f.removeErr = errors.New("simulated remove failure")

	ta, _ := TargetRecordedPrior("csf")
	res := Execute(context.Background(), ta, f.deps())

	if !errors.Is(res.Err, ErrExecuteRemoveFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	// Must NOT report success.
	if res.Terminal == state.StateRestoreExecuted {
		t.Errorf("Terminal = StateRestoreExecuted on removal failure; success must not be reported")
	}
	// Must be one of the non-success terminals (per locked plan).
	switch res.Terminal {
	case state.StateRestoreFailedExecution, state.StateRestoreFailedVerification:
		// acceptable
	default:
		t.Errorf("Terminal = %q on removal failure; want a non-success terminal", res.Terminal)
	}
	if res.Stage != StageRemove {
		t.Errorf("Stage = %q; want %q", res.Stage, StageRemove)
	}
}

// =============================================================================
// 8. Success path call order is exactly:
//      preflight -> insert -> mutate -> verify-active -> verify-authority
//      -> verify-safe -> remove
// =============================================================================

func TestExecute_SuccessPath_ExactCallOrder(t *testing.T) {
	f := newTraceDeps()

	ta, _ := TargetRecordedPrior("ufw")
	res := Execute(context.Background(), ta, f.deps())

	if res.Err != nil {
		t.Fatalf("Execute returned err on success path: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreExecuted {
		t.Errorf("Terminal = %q; want StateRestoreExecuted", res.Terminal)
	}
	if res.Stage != StageComplete {
		t.Errorf("Stage = %q; want %q", res.Stage, StageComplete)
	}
	wantTrace := []string{
		"preflight",         // step 1 §23.1
		"insert",            // step 2 §23.2
		"mutate",            // step 3 §23.3
		"verify-active",     // step 4 §23.4 / §21.1 assertion 1
		"verify-authority",  // step 4              assertion 2
		"verify-safe",       // step 4              assertion 3
		"remove",            // step 5 §23.5
	}
	if !traceEqual(f.trace, wantTrace) {
		t.Errorf("call order mismatch.\n got: %v\nwant: %v", f.trace, wantTrace)
	}
}

// =============================================================================
// 9. PanelNative success: panel resolves via §20 mapping, mutation gets
//    the resolved firewall string (NOT the panel string)
// =============================================================================

func TestExecute_PanelNative_DirectAdmin_ResolvesToCSF(t *testing.T) {
	f := newTraceDeps()

	ta, _ := TargetPanelNative(detect.PanelDirectAdmin)
	res := Execute(context.Background(), ta, f.deps())

	if res.Err != nil {
		t.Fatalf("Execute returned err: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreExecuted {
		t.Errorf("Terminal = %q; want StateRestoreExecuted", res.Terminal)
	}
	// Each downstream call must have seen "csf", not "directadmin".
	if f.lastFirewallTypePreflight != "csf" {
		t.Errorf("preflight saw %q; want csf", f.lastFirewallTypePreflight)
	}
	if f.lastFirewallTypeMutate != "csf" {
		t.Errorf("mutate saw %q; want csf", f.lastFirewallTypeMutate)
	}
	if f.lastFirewallTypeVerify != "csf" {
		t.Errorf("verify saw %q; want csf", f.lastFirewallTypeVerify)
	}
}

// =============================================================================
// 10. PanelNative unmapped panel refuses BEFORE preflight/safety-net/mutation
// =============================================================================

func TestExecute_PanelNative_UnmappedPanel_RefusesBeforeAnyDepCall(t *testing.T) {
	f := newTraceDeps()

	// CPanel is intentionally unmapped per commit 3A.
	ta, _ := TargetPanelNative(detect.PanelCPanel)
	res := Execute(context.Background(), ta, f.deps())

	if res.Err == nil {
		t.Fatalf("Execute accepted unmapped panel; want error")
	}
	if !errors.Is(res.Err, ErrUnmappedPanel) {
		t.Errorf("error chain missing ErrUnmappedPanel: %v", res.Err)
	}
	if res.Terminal != state.StateRestoreFailedExecution {
		t.Errorf("Terminal = %q; want StateRestoreFailedExecution", res.Terminal)
	}
	if res.Stage != "" {
		t.Errorf("Stage = %q; want empty (refused before §23.1)", res.Stage)
	}
	if len(f.trace) != 0 {
		t.Errorf("unmapped panel reached deps: %v (must refuse before any call)", f.trace)
	}
}

// =============================================================================
// 11. Nil deps refuse cleanly (no panic, no partial state)
// =============================================================================

func TestExecute_NilDeps(t *testing.T) {
	cases := map[string]ExecuteDeps{
		"all-nil": {},
		"missing-preflight": {
			SafetyNet:    newTraceDeps(),
			Mutation:     newTraceDeps(),
			InlineVerify: newTraceDeps(),
		},
		"missing-safety": {
			Preflight:    newTraceDeps(),
			Mutation:     newTraceDeps(),
			InlineVerify: newTraceDeps(),
		},
		"missing-mutation": {
			Preflight:    newTraceDeps(),
			SafetyNet:    newTraceDeps(),
			InlineVerify: newTraceDeps(),
		},
		"missing-verify": {
			Preflight: newTraceDeps(),
			SafetyNet: newTraceDeps(),
			Mutation:  newTraceDeps(),
		},
	}
	for name, deps := range cases {
		t.Run(name, func(t *testing.T) {
			ta, _ := TargetRecordedPrior("ufw")
			res := Execute(context.Background(), ta, deps)
			if !errors.Is(res.Err, ErrExecuteNilDeps) {
				t.Errorf("wrong error class for %s: %v", name, res.Err)
			}
			if res.Terminal != state.StateRestoreFailedExecution {
				t.Errorf("%s: Terminal = %q; want FailedExecution", name, res.Terminal)
			}
		})
	}
}

// =============================================================================
// 12. ExecuteDeps surface offers no method for live re-resolution.
//     Compile-time check: each interface method is what the contract
//     allows, nothing more. We simulate this by asserting the interface
//     surfaces don't grow without notice.
// =============================================================================

func TestExecuteDeps_NoLiveResolutionMethods(t *testing.T) {
	// PreflightDep: must have exactly one method.
	// SafetyNetDep: exactly two. MutationDep: exactly one.
	// InlineVerifyDep: exactly three.
	// We assert by attempting to use the interface with our fake.
	// If the interface grew a re-resolution method, the fake would
	// fail to satisfy it and the package would not compile — meaning
	// this test would fail to build. The act of compiling this file
	// is the assertion.
	var _ PreflightDep = (*traceFakeDeps)(nil)
	var _ SafetyNetDep = (*traceFakeDeps)(nil)
	var _ MutationDep = (*traceFakeDeps)(nil)
	var _ InlineVerifyDep = (*traceFakeDeps)(nil)
}

// =============================================================================
// 13. No fallback path for unmapped panels — covered by test 10 above
//     (unmapped panel refuses; no execution proceeds; no firewall is
//     guessed). Belt-and-braces: ensure no §18.2 firewall string leaks
//     into mutation when the panel has no mapping.
// =============================================================================

func TestExecute_PanelNative_UnmappedPanel_NoMutationFirewallLeak(t *testing.T) {
	f := newTraceDeps()
	ta, _ := TargetPanelNative(detect.PanelHestia) // intentionally unmapped
	_ = Execute(context.Background(), ta, f.deps())

	// No mutation should have seen any firewall type.
	if f.lastFirewallTypeMutate != "" {
		t.Errorf("mutate saw firewallType %q on unmapped-panel refusal path; want empty",
			f.lastFirewallTypeMutate)
	}
}

// =============================================================================
// 14. Execute never writes history / never calls dispatcher / main.
//     File-scan on execute.go for forbidden surfaces.
// =============================================================================

func TestExecute_NoForbiddenSurfaces_FileScan(t *testing.T) {
	// Concrete API/identifier patterns only. Self-documenting comments
	// like "no main.go changes" or "no enable/disable" legitimately
	// reference the forbidden surface to declare its absence;
	// substring matching can't tell "is" from "is not", so we restrict
	// the forbidden list to actual call expressions and binary names.
	forbidden := []string{
		"os/exec",
		"exec.Command",
		"os.WriteFile",
		"os.Create",
		"os.Remove(",
		"os.Rename",
		"syscall.",
		`"nft "`,
		`"systemctl `,
		// Live re-detection APIs (must NOT appear in execute.go)
		"DetectPanel(",
		"uninstall.Probe(",
		"uninstall.Classify(",
		"restore.Decide(",
		// History writes (must NOT appear in execute.go)
		"writeHistory(",
		`"update-history"`,
		// Dispatcher entry point (call expression form)
		"runRestoreDecide(",
		// Forbidden broad behaviors that, if used as call expressions
		// or strings, would indicate scope creep
		`"purge"`,
		`"force-delete"`,
		`"fix all"`,
		`"best effort"`,
		`"best-effort"`,
	}
	body, err := readSelf("execute.go")
	if err != nil {
		t.Fatalf("read execute.go: %v", err)
	}
	for _, pat := range forbidden {
		if strings.Contains(body, pat) {
			t.Errorf("execute.go references forbidden pattern %q", pat)
		}
	}
}

// =============================================================================
// 15. All restore terminal states used truthfully — no terminal misuse
// =============================================================================

func TestExecute_AllTerminalStatesUsedTruthfully(t *testing.T) {
	type tcase struct {
		name         string
		setup        func(*traceFakeDeps)
		ta           func() TargetAuthority
		wantTerminal state.InstallState
	}
	cases := []tcase{
		{
			name:  "success",
			setup: func(*traceFakeDeps) {}, // defaults are happy path
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreExecuted,
		},
		{
			name: "preflight-refusal",
			setup: func(f *traceFakeDeps) {
				f.preflightOK = false
			},
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreFailedExecution,
		},
		{
			name: "insert-failure",
			setup: func(f *traceFakeDeps) {
				f.insertErr = errors.New("x")
			},
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreFailedExecution,
		},
		{
			name: "mutate-failure",
			setup: func(f *traceFakeDeps) {
				f.mutateErr = errors.New("x")
			},
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreFailedExecution,
		},
		{
			name: "verify-fail-active",
			setup: func(f *traceFakeDeps) {
				f.activeRet = false
			},
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreFailedVerification,
		},
		{
			name: "verify-fail-authority",
			setup: func(f *traceFakeDeps) {
				f.authorityRet = uninstall.AuthorityNFTBan
			},
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreFailedVerification,
		},
		{
			name: "verify-fail-safe",
			setup: func(f *traceFakeDeps) {
				f.safeRet = false
			},
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreFailedVerification,
		},
		{
			name: "verify-dep-error",
			setup: func(f *traceFakeDeps) {
				f.activeErr = errors.New("x")
			},
			ta: func() TargetAuthority {
				ta, _ := TargetRecordedPrior("ufw")
				return ta
			},
			wantTerminal: state.StateRestoreFailedVerification,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newTraceDeps()
			tc.setup(f)
			res := Execute(context.Background(), tc.ta(), f.deps())
			if res.Terminal != tc.wantTerminal {
				t.Errorf("Terminal = %q; want %q", res.Terminal, tc.wantTerminal)
			}
		})
	}
}

// =============================================================================
// 16. StateRestoreDegraded is NOT used in commit 3C (no degraded
//     condition is implemented yet). Belt-and-braces check.
// =============================================================================

func TestExecute_DegradedNotUsedInCommit3C(t *testing.T) {
	// Walk every test scenario above and assert none returned
	// StateRestoreDegraded. (The explicit table-driven test above
	// already covers this — this is a separate, focused assertion.)
	scenarios := []func(*traceFakeDeps){
		func(*traceFakeDeps) {},
		func(f *traceFakeDeps) { f.preflightOK = false },
		func(f *traceFakeDeps) { f.insertErr = errors.New("x") },
		func(f *traceFakeDeps) { f.mutateErr = errors.New("x") },
		func(f *traceFakeDeps) { f.activeRet = false },
		func(f *traceFakeDeps) { f.authorityRet = uninstall.AuthorityNone },
		func(f *traceFakeDeps) { f.safeRet = false },
		func(f *traceFakeDeps) { f.removeErr = errors.New("x") },
	}
	ta, _ := TargetRecordedPrior("ufw")
	for i, setup := range scenarios {
		f := newTraceDeps()
		setup(f)
		res := Execute(context.Background(), ta, f.deps())
		if res.Terminal == state.StateRestoreDegraded {
			t.Errorf("scenario %d returned StateRestoreDegraded; commit 3C does not implement a degraded path", i)
		}
	}
}

// =============================================================================
// helpers
// =============================================================================

func traceEqual(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}
