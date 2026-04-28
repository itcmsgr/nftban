// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore Execute Orchestration (PR-25 §23)
// =============================================================================
// meta:name="restore_execute"
// meta:type="package"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3C — Execute orchestrates the §23 six-step sequence using primitives from 3A/3B. No dispatcher wiring, no history writes, no main.go changes. All mutation goes through injected dependencies; Execute never directly touches kernel/filesystem/services."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/uninstall,github.com/itcmsgr/nftban/internal/installer/state"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package restore

import (
	"context"
	"errors"
	"fmt"

	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// PreflightDep answers the §23.1 pre-mutation question:
//
// "Is the resolved TargetAuthority still valid right now?"
//
// Implementations check, at minimum, that the authorized target's
// runtime preconditions hold (e.g. the panel-mapped firewall package
// is still installed; the recorded-prior firewall service unit still
// exists). Production implementations are NOT in this commit.
//
// The interface deliberately does NOT take a TargetAuthority by value
// to discourage re-derivation — it carries only the resolved
// firewallType the planner produced. Callers that need authority Kind
// for branching read it from Execute's TargetAuthority argument
// directly.
type PreflightDep interface {
	// PreflightTarget reports whether the resolved firewallType is
	// still a valid execution target right now. Returns nil error +
	// true on go. Returns nil error + false on logical refusal.
	// Returns non-nil error on dep failure (treated as a hard
	// refusal: §23.1 refusal must be non-mutating).
	PreflightTarget(ctx context.Context, firewallType string) (bool, error)
}

// MutationDep performs the §23.3 minimal target-specific kernel +
// service-run-state changes. The interface is intentionally narrow —
// the operation is "switch authority to this firewall and start its
// service run-state". No unit-file edits, no enable/disable, no
// filesystem cleanup.
//
// The dep is responsible for translating the firewallType string
// into the appropriate native operations. Execute does not unpack
// the mapping further.
type MutationDep interface {
	// MutateToTarget performs the kernel + run-state mutation
	// required to make firewallType the authoritative firewall.
	// Returns nil on success, non-nil error on any failure.
	// Implementations MUST leave the safety net (inserted by Execute
	// step 2 prior to this call) in place even on failure — Execute
	// chooses the terminal state and decides safety-net handling.
	MutateToTarget(ctx context.Context, firewallType string) error
}

// ExecuteDeps bundles the four dependency seams Execute needs.
// Constructed by the dispatcher (commit 4) with production
// implementations; tests in this commit construct fakes.
type ExecuteDeps struct {
	Preflight    PreflightDep
	SafetyNet    SafetyNetDep
	Mutation     MutationDep
	InlineVerify InlineVerifyDep
}

// ExecuteResult carries the outcome of one Execute call.
type ExecuteResult struct {
	// Terminal is the §22 terminal state the caller should record.
	// One of:
	//   StateRestoreExecuted              — full success
	//   StateRestoreFailedExecution       — preflight refusal,
	//                                       insert failure, mutate
	//                                       failure
	//   StateRestoreFailedVerification    — inline verification
	//                                       failed (assertion or dep
	//                                       error); safety net retained
	// StateRestoreDegraded is NOT returned by this commit; per the
	// locked plan, it is used only if the contract defines a
	// degraded-but-executed condition, and no such condition is
	// implemented in commit 3C. Adding it requires a contract
	// amendment.
	Terminal state.InstallState

	// Stage names the §23 step that produced the terminal state.
	// Useful for logging and ordering tests. Values are constants
	// declared below (StagePreflight, StageInsert, StageMutate,
	// StageVerify, StageRemove, StageComplete).
	Stage string

	// Err is non-nil when a dep call returned an error or an input
	// invariant was violated. nil on the success path.
	Err error

	// VerifyResult is captured when verification ran (Stage ==
	// StageVerify or later). Empty otherwise.
	VerifyResult VerifyResult
}

// Stage names — §23 step labels for the Stage field above.
const (
	StagePreflight = "preflight"      // §23.1
	StageInsert    = "insert"         // §23.2
	StageMutate    = "mutate"         // §23.3
	StageVerify    = "verify"         // §23.4 (inline verification)
	StageRemove    = "remove"         // §23.5
	StageComplete  = "complete"       // §23.6 success terminal selected
)

// Sentinel errors returned by Execute.
var (
	// ErrExecuteNilDeps is returned when any of the four deps is nil.
	ErrExecuteNilDeps = errors.New("restore: Execute requires non-nil ExecuteDeps with all four members")

	// ErrExecuteRefusedNoneTarget is returned when Execute is called
	// with TargetAuthority{} (zero value) or TargetNone(). PR-25
	// must not run on a None target (contract §24).
	ErrExecuteRefusedNoneTarget = errors.New("restore: Execute refused — TargetAuthority kind is None (§24)")

	// ErrExecutePreflightRefused is returned when the dep's
	// preflight check returns false (logical refusal) or an error.
	// Either way, no mutation occurred.
	ErrExecutePreflightRefused = errors.New("restore: Execute refused — preflight (§23.1)")

	// ErrExecuteInsertFailed is returned when safety-net insertion
	// fails. No mutation occurred.
	ErrExecuteInsertFailed = errors.New("restore: Execute aborted — safety-net insert (§23.2)")

	// ErrExecuteMutateFailed is returned when target mutation fails.
	// Safety net is still in place; no removal.
	ErrExecuteMutateFailed = errors.New("restore: Execute mutation failed (§23.3)")

	// ErrExecuteVerifyFailed is returned when inline verification
	// either errors or returns SafeToRemove=false. Safety net
	// retained per §21.3 / §22.
	ErrExecuteVerifyFailed = errors.New("restore: Execute inline verification failed (§21.1, §23.4)")

	// ErrExecuteRemoveFailed is returned when safety-net removal
	// fails after verification passed. The system is left in a
	// state where mutation succeeded but the safety net was not
	// cleaned up — caller must surface this for operator inspection.
	ErrExecuteRemoveFailed = errors.New("restore: Execute safety-net removal failed (§23.5)")
)

// expectedAuthorityFor maps the resolved TargetAuthority Kind to the
// post-mutation authority class expected by inline verification.
// Both RecordedPrior and PanelNative restoration land on
// AuthorityExternal (the panel or recorded firewall is now
// authoritative; nftban is no longer the authority).
//
// Default branch (per contract §18.4) panics — Kind=None must have
// been refused at the top of Execute, so reaching this helper with
// None is an unreachable invariant violation.
func expectedAuthorityFor(kind TargetAuthorityKind) uninstall.CurrentAuthority {
	switch kind {
	case TargetAuthorityKindRecordedPrior, TargetAuthorityKindPanelNative:
		return uninstall.AuthorityExternal
	case TargetAuthorityKindNone:
		// Should be unreachable — Execute refuses None at step 0.
		// If we got here, the caller bypassed the refusal path.
		mustBeKnownKind(kind)
		return uninstall.AuthorityNone // unreachable; satisfies compiler
	default:
		mustBeKnownKind(kind)
		return uninstall.AuthorityNone // unreachable; satisfies compiler
	}
}

// resolveFirewallType returns the concrete §18.2 firewall-type string
// for a constructed-and-validated TargetAuthority. PanelNative resolves
// via the §20 static mapping; RecordedPrior reads its own field.
//
// This helper does NOT re-construct or re-validate TargetAuthority —
// the planner already did that. It only translates the Kind into a
// firewallType for downstream deps.
func resolveFirewallType(t TargetAuthority) (string, error) {
	switch t.Kind() {
	case TargetAuthorityKindRecordedPrior:
		// Payload invariant §18.3 guarantees non-empty + known.
		return t.FirewallType(), nil
	case TargetAuthorityKindPanelNative:
		return ResolvePanelFirewall(t.Panel())
	case TargetAuthorityKindNone:
		return "", ErrExecuteRefusedNoneTarget
	default:
		mustBeKnownKind(t.Kind())
		return "", nil // unreachable
	}
}

// Execute runs the §23 six-step ordered sequence for a frozen
// TargetAuthority. INV-PR25-AUTHORITY-IMMUTABILITY (§17.3): t MUST be
// the value the planner returned; Execute does not re-derive it and
// the deps must not refresh it mid-flight.
//
// Step order (no reordering, no skipping):
//
//   1. Preflight target validation (§23.1)
//   2. Safety net insertion        (§23.2)
//   3. Target-specific mutation    (§23.3)
//   4. Inline verification         (§23.4 / §21.1)
//   5. Safety net removal          (§23.5 / §21.3)
//   6. Terminal state selection    (§23.6)
//
// Failure modes (truthful terminal mapping):
//
//   - Kind=None / zero-value             → ErrExecuteRefusedNoneTarget
//                                          (Stage="" — refused before
//                                          §23.1; no mutation)
//   - Preflight refusal / error          → StateRestoreFailedExecution
//                                          (Stage=preflight; no mutation,
//                                          no safety net inserted)
//   - Safety-net insert failure          → StateRestoreFailedExecution
//                                          (Stage=insert; no mutation)
//   - Target mutation failure            → StateRestoreFailedExecution
//                                          (Stage=mutate; safety net
//                                          retained; verification skipped;
//                                          remove skipped)
//   - Inline verification failure        → StateRestoreFailedVerification
//                                          (Stage=verify; safety net
//                                          retained per §21.3)
//   - Safety-net removal failure         → StateRestoreFailedVerification
//                                          (Stage=remove; mutation
//                                          succeeded but safety net could
//                                          not be removed; non-success
//                                          terminal so the caller never
//                                          reports success)
//   - All steps pass                     → StateRestoreExecuted
//                                          (Stage=complete)
//
// StateRestoreDegraded is NOT returned by this commit — no degraded-
// but-executed condition is defined in commit 3C. Adding one
// requires a contract amendment.
//
// Execute does NOT call any of the live re-detection APIs
// (detect.DetectPanel, uninstall.Probe, uninstall.Classify,
// restore.Decide). It does NOT write history. It does NOT touch
// dispatcher state. All mutation flows through the four injected deps.
func Execute(ctx context.Context, t TargetAuthority, deps ExecuteDeps) ExecuteResult {
	// Step 0 — input validation. Must come BEFORE every other step.
	// Refusing here is non-mutating: no preflight, no safety net,
	// no dep call.
	if deps.Preflight == nil || deps.SafetyNet == nil || deps.Mutation == nil || deps.InlineVerify == nil {
		return ExecuteResult{
			Terminal: state.StateRestoreFailedExecution,
			Stage:    "",
			Err:      ErrExecuteNilDeps,
		}
	}

	// Step 0 (cont.) — refuse Kind=None / zero value before any
	// mutation. Contract §24.
	if t.Kind() == TargetAuthorityKindNone {
		return ExecuteResult{
			Terminal: state.StateRestoreFailedExecution,
			Stage:    "",
			Err:      ErrExecuteRefusedNoneTarget,
		}
	}

	// Resolve concrete firewall type. PanelNative goes through the
	// §20 static mapping; an unmapped panel refuses here, before
	// any mutation. This is the §20.2 hard refusal path.
	firewallType, err := resolveFirewallType(t)
	if err != nil {
		return ExecuteResult{
			Terminal: state.StateRestoreFailedExecution,
			Stage:    "",
			Err:      fmt.Errorf("restore: Execute target resolution failed: %w", err),
		}
	}

	// Step 1 — preflight (§23.1). Failure is non-mutating.
	ok, perr := deps.Preflight.PreflightTarget(ctx, firewallType)
	if perr != nil {
		return ExecuteResult{
			Terminal: state.StateRestoreFailedExecution,
			Stage:    StagePreflight,
			Err:      fmt.Errorf("%w: %v", ErrExecutePreflightRefused, perr),
		}
	}
	if !ok {
		return ExecuteResult{
			Terminal: state.StateRestoreFailedExecution,
			Stage:    StagePreflight,
			Err:      ErrExecutePreflightRefused,
		}
	}

	// Step 2 — safety-net insertion (§23.2). Failure is still
	// non-mutating: nothing in the kernel is changed in a way that
	// requires net-removal cleanup.
	if err := InsertSafetyNet(ctx, deps.SafetyNet); err != nil {
		return ExecuteResult{
			Terminal: state.StateRestoreFailedExecution,
			Stage:    StageInsert,
			Err:      fmt.Errorf("%w: %v", ErrExecuteInsertFailed, err),
		}
	}

	// Step 3 — minimal target-specific mutation (§23.3). After this
	// point the kernel state has changed. On failure, safety net is
	// RETAINED (we do not call RemoveSafetyNet without a passing
	// inline-verify result, per §21.3), and verification is skipped.
	if err := deps.Mutation.MutateToTarget(ctx, firewallType); err != nil {
		return ExecuteResult{
			Terminal: state.StateRestoreFailedExecution,
			Stage:    StageMutate,
			Err:      fmt.Errorf("%w: %v", ErrExecuteMutateFailed, err),
		}
	}

	// Step 4 — inline verification (§23.4 / §21.1). Three-assertion
	// minimum-sufficient check.
	expected := expectedAuthorityFor(t.Kind())
	vr := InlineVerify(ctx, deps.InlineVerify, firewallType, expected)
	if vr.Err != nil {
		// Dep error during verification = hard fail. Per §21.3 and
		// §22, safety net is retained. Verification result included
		// for caller logging.
		return ExecuteResult{
			Terminal:     state.StateRestoreFailedVerification,
			Stage:        StageVerify,
			Err:          fmt.Errorf("%w: %v", ErrExecuteVerifyFailed, vr.Err),
			VerifyResult: vr,
		}
	}
	if !vr.SafeToRemove {
		// Logical fail (one or more §21.1 assertions returned false).
		// Per §21.3: do NOT call RemoveSafetyNet; safety net retained.
		return ExecuteResult{
			Terminal:     state.StateRestoreFailedVerification,
			Stage:        StageVerify,
			Err:          ErrExecuteVerifyFailed,
			VerifyResult: vr,
		}
	}

	// Step 5 — safety-net removal (§23.5). Only reachable after
	// vr.SafeToRemove == true. We pass verifiedSafe=true to render
	// the §21.3 gate explicitly.
	if err := RemoveSafetyNet(ctx, deps.SafetyNet, true); err != nil {
		// Mutation succeeded, verification said safe, but the actual
		// kernel removal failed. The system is in a non-success
		// state: mutation is in effect but the safety net was not
		// cleaned up. Per the locked rule "do not report success",
		// we surface this as a non-success terminal
		// (StateRestoreFailedVerification — closest existing
		// terminal that retains the safety-net implication).
		return ExecuteResult{
			Terminal:     state.StateRestoreFailedVerification,
			Stage:        StageRemove,
			Err:          fmt.Errorf("%w: %v", ErrExecuteRemoveFailed, err),
			VerifyResult: vr,
		}
	}

	// Step 6 — terminal-state selection (§23.6). All steps passed.
	return ExecuteResult{
		Terminal:     state.StateRestoreExecuted,
		Stage:        StageComplete,
		Err:          nil,
		VerifyResult: vr,
	}
}
