// =============================================================================
// NFTBan v1.98 - Installer ↔ Lifecycle Bridge
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-lifecycle-bridge"
// meta:type="cmd"
// meta:version="1.98.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Bridge between installer phases and lifecycle reporting — observational only"
// meta:inventory.files="cmd/nftban-installer/lifecycle_bridge.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V198_INSTALL_CANONIZATION_CONTRACT.md
// INV-I-004: Lifecycle is OBSERVATIONAL ONLY in v1.98.
//   It mirrors installer decisions for reporting. It does NOT drive them.
//   Installer logic remains the source of execution truth.
// =============================================================================

package main

import (
	"io"
	"os"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/lifecycle"
	"github.com/itcmsgr/nftban/internal/rebuild"
)

// lifecycleBridge observes installer phases and emits lifecycle events.
// INV-I-004: This bridge is OBSERVATIONAL ONLY — it does not influence
// installer execution decisions. Installer remains the execution authority.
type lifecycleBridge struct {
	logger *lifecycle.Logger
	mode   lifecycle.Mode
	// dryRun is the operator's actual --dry-run flag value. PR-22B
	// replaced the previously hard-coded DryRun:false in observeResult
	// with this wired-through value so lifecycle consumers see the real
	// run shape instead of an implicit false.
	dryRun bool
}

// newLifecycleBridge creates a bridge that writes lifecycle events to the
// installer's structured log file by default (v1.160 PR-B).
//
// Before v1.160 the lifecycle logger wrote raw JSON ({"event":"detect"…}, plan,
// result) to os.Stderr — the operator console — interleaved with human phase
// lines, and the events were not preserved in any structured log. v1.160 PR-B
// routes the JSON to the same persistent installer log file the dual logger
// writes to, so the events are kept for post-mortem without cluttering the
// console. Console JSON is opt-in via NFTBAN_LIFECYCLE_JSON=1 or NFTBAN_DEBUG=1.
//
// This change is WHERE-only — the events produced and their timing are
// unchanged (INV-I-004: lifecycle remains observational). The StateFailedAbort
// suppression in main.go is untouched.
func newLifecycleBridge(installerMode string, dryRun bool, log *logging.Logger) *lifecycleBridge {
	mode := mapInstallerMode(installerMode)

	w := lifecycleWriter(log.FileWriter(), lifecycleConsoleOptIn(), os.Stderr, log)

	lb := &lifecycleBridge{
		logger: lifecycle.NewLogger(w, mode, false),
		mode:   mode,
		dryRun: dryRun,
	}

	log.Info("lifecycle bridge initialized (mode=%s, dry_run=%v, observational only)", mode, dryRun)
	return lb
}

// lifecycleConsoleOptIn reports whether the operator asked for lifecycle JSON on
// the console. v1.160 PR-B: env-gated to match the existing NFTBAN_LIFECYCLE
// style (no CLI flag needed). NFTBAN_LIFECYCLE_JSON=1 is the explicit knob;
// NFTBAN_DEBUG=1 also enables it for general debugging.
func lifecycleConsoleOptIn() bool {
	return os.Getenv("NFTBAN_LIFECYCLE_JSON") == "1" || os.Getenv("NFTBAN_DEBUG") == "1"
}

// lifecycleWriter selects the io.Writer for lifecycle JSON events (v1.160 PR-B).
//
// Routing:
//   - default (no console opt-in): the structured log file, if available.
//   - console opt-in true: file + console via io.MultiWriter (or console alone
//     if no file is available) — this restores the pre-v1.160 console behavior
//     additively.
//   - no file and no opt-in: io.Discard, with a one-line Debug note so the
//     reason the events are dropped is recorded (the dual logger is in
//     console-only mode, so there is nowhere durable to send them).
//
// Pure aside from the optional Debug note; the writers are injected so the
// routing decision is unit-testable. `console` is normally os.Stderr.
func lifecycleWriter(file io.Writer, consoleOptIn bool, console io.Writer, log *logging.Logger) io.Writer {
	if consoleOptIn {
		if file != nil {
			return io.MultiWriter(file, console)
		}
		return console
	}
	if file != nil {
		return file
	}
	// No durable sink and no opt-in: discard, but record why.
	if log != nil {
		log.Debug("lifecycle JSON discarded: no installer log file open and no console opt-in (NFTBAN_LIFECYCLE_JSON/NFTBAN_DEBUG)")
	}
	return io.Discard
}

// observeDetect records the DETECT stage from installer phase data.
func (lb *lifecycleBridge) observeDetect(pd *phaseData, sf *state.StateFile) {
	auth := lifecycle.AuthorityState{
		Owner:  mapAuthority(string(pd.decision)),
		Health: lifecycle.HealthDown, // pre-install, health unknown
	}

	det := lifecycle.Detection{
		ConflictingFirewall: len(pd.conflicts) > 0,
		KernelValid:         false, // pre-install
		ValidatorConsistent: false, // pre-install
		SSHSafe:             pd.sshPort > 0,
	}

	lb.logger.LogDetect(auth, det)
}

// observePlan records the PLAN stage from authority decision.
//
// PR-22B fix: the previous switch compared pd.decision (authority.Decision,
// UPPERCASE values like "TAKEOVER") against lowercase string literals, so
// the switch silently hit the default case in every run — meaning every
// lifecycle consumer saw "PreserveAuthority" regardless of what the
// installer actually decided. This is the exact class of lifecycle truth
// drift the audit flagged. Now pinned to the authority package constants.
func (lb *lifecycleBridge) observePlan(pd *phaseData) {
	var actions []lifecycle.Action
	switch pd.decision {
	case authority.Takeover, authority.Fresh:
		actions = []lifecycle.Action{lifecycle.ActionTakeAuthority}
	case authority.Update:
		actions = []lifecycle.Action{lifecycle.ActionPreserveAuthority}
	case authority.Abort:
		actions = []lifecycle.Action{lifecycle.ActionAbort}
	case authority.Ambiguous:
		// PR-22B: Ambiguous hosts cannot be assumed preserving OR taking —
		// the plan action that best reflects reality is "take authority"
		// (nftban will claim the firewall via rebuild) plus a conservative
		// emergency-SSH injection, but downstream lifecycle consumers
		// should see it as a Takeover-class action, not Preserve.
		actions = []lifecycle.Action{lifecycle.ActionTakeAuthority}
	default:
		actions = []lifecycle.Action{lifecycle.ActionPreserveAuthority}
	}

	plan := lifecycle.Plan{
		Actions: actions,
	}

	// Read v1.96 recovery state
	lastOp := readRecoveryState()

	lb.logger.LogPlan(plan, lastOp)
}

// observeResult records the FINAL stage from installer outcome.
//
// PR-22B fix: DryRun is now wired from the operator's actual flag (see
// newLifecycleBridge). Previously hard-coded to false, which meant every
// lifecycle consumer saw the same misleading "real run" signal regardless
// of how the installer was invoked.
func (lb *lifecycleBridge) observeResult(sf *state.StateFile) {
	result := lifecycle.RunResult{
		SchemaVersion: lifecycle.OutputSchemaVersion,
		Mode:          lb.mode,
		DryRun:        lb.dryRun,
		Timestamp:     time.Now(),
	}

	// Map installer state to lifecycle outcome
	switch sf.State {
	case state.StateCommitted:
		result.Outcome = lifecycle.OutcomeSuccess
		result.Stage = lifecycle.StageFinal
		result.Authority.Resulting = lifecycle.AuthorityState{
			Owner: lifecycle.AuthorityNFTBan, Health: lifecycle.HealthProtected,
		}
	case state.StateDegraded:
		result.Outcome = lifecycle.OutcomeFailed
		result.Stage = lifecycle.StageVerify
		result.Authority.Resulting = lifecycle.AuthorityState{
			Owner: lifecycle.AuthorityNFTBan, Health: lifecycle.HealthDegraded,
		}
	default:
		result.Outcome = lifecycle.OutcomeFailed
		result.Stage = lifecycle.StageApply
		result.Authority.Resulting = lifecycle.AuthorityState{
			Owner: lifecycle.AuthorityNFTBan, Health: lifecycle.HealthDown,
		}
	}

	result.LastOperation = readRecoveryState()

	lb.logger.LogResult(result)
}

// mapInstallerMode converts installer mode string to lifecycle mode.
func mapInstallerMode(mode string) lifecycle.Mode {
	switch mode {
	case "install", "source":
		return lifecycle.ModeInstall
	case "upgrade":
		return lifecycle.ModeUpdate
	case "remove", "purge":
		return lifecycle.ModeUninstall
	default:
		return lifecycle.ModeInstall
	}
}

// mapAuthority converts installer authority decision to lifecycle owner.
//
// PR-22B fix: input values are authority.Decision strings ("TAKEOVER",
// "FRESH", "UPDATE", "ABORT", "AMBIGUOUS" — all uppercase). Previously
// compared against lowercase string literals, so the switch always hit
// the default case. Now pinned to authority constants.
func mapAuthority(decision string) lifecycle.AuthorityOwner {
	switch authority.Decision(decision) {
	case authority.Takeover:
		return lifecycle.AuthorityExternal // was external, taking over
	case authority.Fresh:
		return lifecycle.AuthorityNone
	case authority.Update:
		return lifecycle.AuthorityNFTBan
	case authority.Abort:
		return lifecycle.AuthorityExternal
	case authority.Ambiguous:
		// Ambiguous: the host's kernel state is inconsistent. Report it as
		// "unknown" to lifecycle consumers rather than silently collapsing
		// to nftban or external ownership.
		return lifecycle.AuthorityUnknown
	default:
		return lifecycle.AuthorityNone
	}
}

// readRecoveryState reads v1.96 recovery marker for lifecycle output.
func readRecoveryState() lifecycle.LastOperation {
	lo := lifecycle.LastOperation{Result: "SUCCESS"}

	marker, err := rebuild.ReadMarker()
	if err != nil || marker == nil {
		return lo
	}

	lo.Result = string(marker.OperationResult)
	lo.FailureClass = string(marker.FailureClass)
	lo.RecoveryPending = marker.ShouldDeferRetry()
	lo.LastRebuildFailed = marker.OperationResult != rebuild.ResultSuccess

	return lo
}
