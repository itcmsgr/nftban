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

// runRestoreDecide orchestrates the PR-24 decision engine invocation.
// Returns the process exit code derived from the decision output.
func runRestoreDecide(_ context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
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
			Restore:           cfg.restorePriorAuthority,
			PanelAutoTakeover: cfg.panelAutoTakeover,
		},
		PanelPresent: panelPresent,
	}

	// 7. Evaluate — pure, deterministic, no side effects.
	result := restore.Decide(input)

	// 8. Structured decision-path log record (seed §2 logging obligation).
	log.Info("restore decide: result output=%s rule=%s reason=%q",
		result.Output, result.Rule, result.Reason)
	log.Info("restore decide: inputs authority=%s ambiguity=%s prior=%s restore=%v panel_auto=%v panel_present=%v",
		input.Authority, input.Ambiguity, input.Prior,
		input.Flags.Restore, input.Flags.PanelAutoTakeover, input.PanelPresent)

	// 9. Transition to terminal state + return exit code.
	newState, phase := restoreStateForOutput(result.Output)
	_ = sf.Transition(newState, phase, result.Reason)

	// Operator-facing output (stdout).
	switch result.Output {
	case restore.OutputProceed:
		log.Result("[NFTBan] restore decision: PROCEED — %s", result.Reason)
		log.Result("[NFTBan] note: PR-24 is the decision engine only; execution of restoration is deferred to a later PR.")
	case restore.OutputRefuse:
		log.Result("[NFTBan] restore decision: REFUSE — %s", result.Reason)
	case restore.OutputRequireExplicitIntent:
		log.Result("[NFTBan] restore decision: REQUIRE_EXPLICIT_INTENT — %s", result.Reason)
	}

	return sf.State.ExitCode()
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

// restoreStateForOutput maps the decision output to the state-machine
// terminal (or non-terminal handoff) state. Phase is always
// PhaseDetect for this dispatcher — the engine's job IS detection +
// decision; there is no later phase to attribute to.
func restoreStateForOutput(out restore.Output) (state.InstallState, state.Phase) {
	switch out {
	case restore.OutputProceed:
		return state.StateRestoreDecided, state.PhaseDetect
	case restore.OutputRefuse:
		return state.StateRestoreRefused, state.PhaseDetect
	case restore.OutputRequireExplicitIntent:
		return state.StateRestoreIntentRequired, state.PhaseDetect
	}
	// Unreachable — Decide's return type is a closed enum guarded by
	// TestDecide_OutputClosedEnum. A fourth value here means a
	// contract regression.
	panic("restore dispatcher: unknown Output value — contract regression")
}
