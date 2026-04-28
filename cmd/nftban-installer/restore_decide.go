// =============================================================================
// NFTBan v1.100 PR-24 — Restore Policy Decision Dispatcher
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-restore-decide"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="--mode=restore dispatcher: gather inputs, call Decide, transition state"
// meta:inventory.files="cmd/nftban-installer/restore_decide.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// This dispatcher is the ONLY entry into the PR-24 restoration policy
// decision engine. Reached only when cfg.mode == "restore" (flags.go
// rejects any incompatible flag combination at parse time).
//
// Responsibilities:
//
//   1. Classify current authority (via uninstall.Classify).
//   2. Probe prior-authority record (via uninstall.Probe).
//   3. Reduce probe result + freshness window into a restore.PriorState.
//   4. Detect panel context (via detect.DetectPanel).
//   5. Assemble restore.DecisionInput.
//   6. Call restore.Decide — pure, no side effects.
//   7. Log structured decision-path record.
//   8. Transition state file to the terminal (Refused / IntentRequired)
//      or non-terminal handoff (Decided) state.
//   9. Return the correct exit code.
//
// Hard discipline: NO kernel / service / filesystem mutation beyond the
// state-file write that Transition() performs. NO history entry (Option
// A continues; main.go's writeHistory gate plus IsApplyTerminal=false
// for all three restore states closes the write path defensively).
//
// =============================================================================
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// runRestoreDecide orchestrates the PR-24 decision engine invocation
// AND, on PROCEED, the PR-25 execution engine.
//
// On result.Output == OutputProceed, the dispatcher calls
// restore.PlanFromDecision to resolve TargetAuthority, then
// restore.Execute to run the §23 six-step sequence, then persists
// whatever terminal state Execute returns. The four PR-25 execution
// terminals (StateRestoreExecuted / StateRestoreFailedExecution /
// StateRestoreFailedVerification / StateRestoreDegraded) replace the
// PR-24 transitional StateRestoreDecided on the PROCEED path.
//
// REFUSE and REQUIRE_EXPLICIT_INTENT paths are byte-identical to
// PR-24: the dispatcher transitions to StateRestoreRefused /
// StateRestoreIntentRequired and exits with the same code PR-24 used.
// No Plan / Execute call on these paths.
//
// Production deps live in restore_deps.go (Preflight, SafetyNet,
// Mutation dispatch, InlineVerify) + restore_deps_csf.go (the csf
// branch of MutateToTarget). Amendment 1 (§§30-36) authorizes csf
// only; non-csf §18.2 firewalls land at StateRestoreFailedExecution
// with ErrCSFRestoreOnlyAuthorized; firewalls outside §18.2 land
// with ErrRestoreMutationUnknownFirewall. The dispatcher persists
// each terminal truthfully and main.go's writeHistory gate
// (mode != "restore", at main.go:132) keeps every restore-mode
// outcome out of update-history.json.
//
// Returns the process exit code derived from the persisted state.
func runRestoreDecide(ctx context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	log.Info("restore decide starting (mode=restore)")

	// 1. Classify authority.
	auth := uninstall.Classify(exec, log)
	log.Info("restore decide: authority=%s ambiguity=%s external=%s",
		auth.State, auth.Ambiguity, auth.External)

	// 2. Probe prior-record.
	probe := uninstall.Probe(exec, log)
	log.Info("restore decide: prior-record state=%s incomplete_reason=%s",
		probe.State, probe.IncompleteReason)

	// 3. Preflight errors (seed §9): classifier invariant violations
	// and record malformation short-circuit to ExitFatal WITHOUT
	// emitting a lattice output. This keeps the three-output space
	// closed.
	if probe.State == uninstall.PriorRecordMalformed {
		log.Error("restore decide: preflight FATAL — prior-record file malformed; lattice does not apply")
		fmt.Fprintln(os.Stderr, "error: prior-authority record is malformed; manual inspection required")
		fmt.Fprintln(os.Stderr, "       see: "+uninstall.PriorAuthorityPath)
		return state.ExitFatal
	}
	if auth.State == uninstall.AuthorityAmbiguous && auth.Ambiguity != uninstall.AmbiguityConflictExternal && auth.Ambiguity != uninstall.AmbiguityOrphanNFTBan {
		log.Error("restore decide: preflight FATAL — classifier returned Ambiguous without a supported sub-kind (got %q)",
			auth.Ambiguity)
		fmt.Fprintln(os.Stderr, "error: classifier invariant violated — Ambiguous state without supported sub-kind")
		return state.ExitFatal
	}

	// 4. Reduce probe + freshness window into restore.PriorState.
	priorState := reducePriorState(probe)
	log.Info("restore decide: prior-state (reduced) = %s", priorState)

	// 5. Panel detection.
	panel := detect.DetectPanel(exec, log)
	panelPresent := detect.HasPanel(panel)
	log.Info("restore decide: panel=%s present=%v", panel, panelPresent)

	// 6. Build the decision input. Note: --restore-prior-authority in
	// the CLI surface maps to Flags.Restore in the engine.
	input := restore.DecisionInput{
		Authority: auth.State,
		Ambiguity: auth.Ambiguity,
		Prior:     priorState,
		Flags: restore.Flags{
			Restore:            cfg.restorePriorAuthority,
			PanelAutoTakeover:  cfg.panelAutoTakeover,
			AcceptOrphanNFTBan: cfg.acceptOrphanNFTBan,
		},
		PanelPresent: panelPresent,
		Panel:        panel,
	}

	// 6b. Amendment 2 §54.3: gather orphan-restore evidence ONLY when
	// the candidate triple is otherwise present. This avoids
	// unnecessary live reads on every restore-mode invocation, and
	// preserves the §51.3 Option B boundary (no iptables introspection)
	// by only running the predicate where it matters.
	if auth.State == uninstall.AuthorityNFTBan &&
		priorState == restore.PriorStateNoRecord &&
		panel == detect.PanelDirectAdmin &&
		cfg.panelAutoTakeover &&
		cfg.acceptOrphanNFTBan {
		ev := gatherOrphanEvidence(exec, log, panel, auth, probe, cfg)
		input.OrphanEvidence = &ev
		log.Info("restore decide: orphan-evidence gathered all_true=%v failed_row=%q",
			ev.AllTrue(), ev.FailedRowID())
	}

	// 7. Evaluate — pure, deterministic, no side effects.
	result := restore.Decide(input)

	// 8. Structured decision-path log record (seed §2 logging obligation).
	log.Info("restore decide: result output=%s rule=%s reason=%q",
		result.Output, result.Rule, result.Reason)
	log.Info("restore decide: inputs authority=%s ambiguity=%s prior=%s restore=%v panel_auto=%v panel_present=%v",
		input.Authority, input.Ambiguity, input.Prior,
		input.Flags.Restore, input.Flags.PanelAutoTakeover, input.PanelPresent)

	// 9. Branch on output.
	switch result.Output {

	case restore.OutputRefuse:
		// PR-24 byte-identical: terminal refusal, exit ExitRefused.
		_ = sf.Transition(state.StateRestoreRefused, state.PhaseDetect, result.Reason)
		log.Result("[NFTBan] restore decision: REFUSE — %s", result.Reason)
		return sf.State.ExitCode()

	case restore.OutputRequireExplicitIntent:
		// PR-24 byte-identical: terminal intent-required, exit
		// ExitIntentRequired.
		_ = sf.Transition(state.StateRestoreIntentRequired, state.PhaseDetect, result.Reason)
		log.Result("[NFTBan] restore decision: REQUIRE_EXPLICIT_INTENT — %s", result.Reason)
		return sf.State.ExitCode()

	case restore.OutputProceed:
		// PR-25 commit 4: PROCEED flows to execution. Extracted for
		// unit testability — see runRestoreExecutionFromProceed.
		log.Result("[NFTBan] restore decision: PROCEED — %s", result.Reason)
		return runRestoreExecutionFromProceed(ctx, exec, sf, log, result, input, probe.Record, panel)
	}

	// Unreachable: restore.Decide returns one of the three closed-enum
	// values. A fourth value here means a contract regression caught
	// by the G4-RESTORE-DECISION-CORRECTNESS CI gate.
	panic("restore dispatcher: unknown Output value — contract regression")
}

// reducePriorState maps uninstall.ProbeResult onto the normalized
// restore.PriorState consumed by the engine, including the 365-day
// freshness-window check for Stale classification.
//
// The staleness window is fixed at restore.StalenessWindowDays per
// seed §3.B; configurability is a seed §15 follow-up item and is
// intentionally not implemented here.
func reducePriorState(probe *uninstall.ProbeResult) restore.PriorState {
	switch probe.State {
	case uninstall.PriorNoRecord:
		return restore.PriorStateNoRecord

	case uninstall.PriorRecordIncomplete:
		return restore.PriorStateIncomplete

	case uninstall.PriorRecordUsableActive:
		if isStale(probe.Record) {
			return restore.PriorStateStale
		}
		return restore.PriorStateCompleteActive

	case uninstall.PriorRecordUsableInactive:
		if isStale(probe.Record) {
			return restore.PriorStateStale
		}
		return restore.PriorStateCompleteInactive
	}

	// PriorRecordMalformed is handled as a preflight error before this
	// function is called. Any other value indicates an upstream schema
	// addition without dispatcher update — treat as Incomplete (the
	// conservative truthful classification).
	return restore.PriorStateIncomplete
}

// isStale returns true if the record's RecordedAt is older than the
// freshness window. A nil RecordedAt is treated as stale rather than
// fresh — uninstall.Probe already reclassifies records lacking the
// field as Incomplete, so reaching here with nil indicates an
// upstream invariant break and we fail closed.
func isStale(rec *uninstall.PriorRecord) bool {
	if rec == nil || rec.RecordedAt == nil {
		return true
	}
	age := time.Since(*rec.RecordedAt)
	return age > time.Duration(restore.StalenessWindowDays)*24*time.Hour
}

// (PR-25 commit 4 removed the previous restoreStateForOutput helper.
// PROCEED no longer maps to a single transitional state; it flows
// through PlanFromDecision + Execute to produce one of four PR-25
// execution terminals. REFUSE and REQUIRE_EXPLICIT_INTENT now
// transition inline within runRestoreDecide above; the helper is
// no longer needed and was unused after the refactor.)

// runRestoreExecutionFromProceed orchestrates the PR-25 §23 path on
// a PROCEED decision. Extracted from runRestoreDecide so unit tests
// can exercise the planner + executor + persist flow with controlled
// inputs (without faking the upstream classify/probe/detect
// executor calls).
//
// The function:
//
//   1. Resolves TargetAuthority via restore.PlanFromDecision.
//      Planner refusal → StateRestoreFailedExecution; no Execute.
//   2. Constructs ExecuteDeps via the package-level newRestoreDeps
//      factory (production path = stubs in commit 4; tests swap).
//   3. Calls restore.Execute and persists whatever terminal state
//      it returns.
//   4. Returns the persisted state's exit code.
//
// INV-PR25-AUTHORITY-IMMUTABILITY (§17.3): the planner result is the
// authoritative TargetAuthority. Execute does not re-derive it; the
// dispatcher does not consult anything besides what the planner
// returned + what the deps observe at verification time.
func runRestoreExecutionFromProceed(
	ctx context.Context,
	exec executor.Executor,
	sf *state.StateFile,
	log *logging.Logger,
	result restore.DecisionResult,
	input restore.DecisionInput,
	priorRec *uninstall.PriorRecord,
	panel detect.PanelType,
) int {
	// Step A — Plan: resolve TargetAuthority once.
	target, planErr := restore.PlanFromDecision(result, input, priorRec, panel)
	if planErr != nil {
		log.Error("restore execute: planner refused PROCEED: %v", planErr)
		_ = sf.Transition(state.StateRestoreFailedExecution, state.PhaseDetect, planErr.Error())
		log.Result("[NFTBan] restore execution: FAILED at planner — %s", planErr.Error())
		return sf.State.ExitCode()
	}
	log.Info("restore execute: target resolved kind=%s firewallType=%s panel=%s",
		target.Kind(), target.FirewallType(), target.Panel())

	// Step B — Construct deps. 4B-3-pre extended the factory to
	// carry priorRec + panel forward to the mutation dep. Both
	// values come from the PR-24 path the planner already used —
	// the dispatcher does NOT re-probe or re-detect them, per
	// INV-PR25-AUTHORITY-IMMUTABILITY (§17.3) + §33 E.7.
	//
	// PR-26-code-A: also resolve firewallType from the target so the
	// inline-verify dep's safety predicate is target-specific (§51.3
	// Option B + §51.4 firewallType plumbing). For Kind=RecordedPrior
	// the value is on the TargetAuthority directly; for Kind=PanelNative
	// the value comes from the static §20 panel mapping
	// (restore.ResolvePanelFirewall). No precomputed targetUnit drift
	// — we pass the raw firewallType identity.
	resolvedFirewallType, ftErr := resolveFirewallTypeForDeps(target)
	if ftErr != nil {
		log.Error("restore execute: firewallType resolution failed: %v", ftErr)
		_ = sf.Transition(state.StateRestoreFailedExecution, state.PhaseDetect, ftErr.Error())
		log.Result("[NFTBan] restore execution: FAILED at firewallType resolution — %s", ftErr.Error())
		return sf.State.ExitCode()
	}
	deps := newRestoreDeps(exec, log, priorRec, panel, resolvedFirewallType)

	// Step C — Execute the §23 six-step sequence.
	execRes := restore.Execute(ctx, target, deps)
	log.Info("restore execute: terminal=%s stage=%s err=%v",
		execRes.Terminal, execRes.Stage, execRes.Err)

	reason := result.Reason
	if execRes.Err != nil {
		reason = execRes.Err.Error()
	}

	// Step D — PR-26-code-D evidence record. Recording-only; no
	// re-derivation of TargetAuthority, no PR-24 re-decision, no
	// validator/module-health probe, no update-history write
	// (§19.2 layer 4 / main.go:132 mode-gate retained).
	//
	// The §48.6 lock requires that, if evidence-write fails AFTER a
	// successful StateRestoreExecuted, we MUST NOT claim "executed"
	// without recording the evidence. The state model already
	// supports StateRestoreDegraded (state/machine.go:152) so we
	// downgrade the terminal in that case.
	finalTerminal := execRes.Terminal
	finalReason := reason
	rec := buildRestoreEvidenceRecord(exec, log, target, execRes)
	evidenceErr := writeRestoreEvidenceRecord(ctx, exec, rec, log)
	if evidenceErr != nil {
		log.Warn("restore evidence: write failed: %v", evidenceErr)
		if execRes.Terminal == state.StateRestoreExecuted {
			finalTerminal = state.StateRestoreDegraded
			finalReason = "restore executed but evidence-write failed: " + evidenceErr.Error()
			log.Warn("restore evidence: downgrading StateRestoreExecuted -> StateRestoreDegraded — successful restore cannot claim executed without recorded evidence")
		}
	}

	_ = sf.Transition(finalTerminal, state.PhaseDetect, finalReason)

	// Step E — Operator-facing output reflects the (possibly
	// downgraded) terminal.
	switch finalTerminal {
	case state.StateRestoreExecuted:
		log.Result("[NFTBan] restore execution: COMPLETED — authorized restore is in effect")
	case state.StateRestoreDegraded:
		log.Result("[NFTBan] restore execution: COMPLETED with warnings — %s", finalReason)
	case state.StateRestoreFailedExecution:
		log.Result("[NFTBan] restore execution: FAILED at %s — %s", execRes.Stage, finalReason)
	case state.StateRestoreFailedVerification:
		log.Result("[NFTBan] restore execution: FAILED VERIFICATION at %s — safety net retained — %s",
			execRes.Stage, finalReason)
	}

	return sf.State.ExitCode()
}

