// =============================================================================
// NFTBan v1.73 - Installer State Machine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-state-machine"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Install state enum, phase enum, exit codes, resume logic"
// meta:inventory.files="internal/installer/state/machine.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package state

// InstallState represents the current state of the installation process.
type InstallState string

const (
	StateFilesInstalled   InstallState = "FILES_INSTALLED"
	StateDetectComplete   InstallState = "DETECT_COMPLETE"
	StatePrepareComplete  InstallState = "PREPARE_COMPLETE"
	StateSwitchComplete   InstallState = "SWITCH_COMPLETE"
	StateServicesComplete InstallState = "SERVICES_COMPLETE"
	StateCommitted        InstallState = "COMMITTED"
	StateDegraded         InstallState = "DEGRADED"
	StateFailedSSH        InstallState = "FAILED_SSH_UNKNOWN"
	StateFailedAbort      InstallState = "FAILED_AUTHORITY_ABORT"
	StateFailedRender     InstallState = "FAILED_RENDER"
	StateFailedRebuild    InstallState = "FAILED_REBUILD"
	StateFailedNoFirewall InstallState = "FAILED_NO_FIREWALL"
	StateFailedTakeover   InstallState = "FAILED_TAKEOVER"

	// StateUninstallPlanning is the terminal state for v1.100 PR-22's
	// detect + dry-run plan orchestrator. The planner reaches this
	// state after classifying current authority, probing the optional
	// prior-authority record, and rendering the release plan — without
	// invoking any mutation phase. Later v1.100 PRs (PR-23/25) add the
	// mutation-carrying uninstall states; PR-22 deliberately ships only
	// the planning state so the scope-boundary block in plan output
	// remains literally true: no phase beyond Planning exists yet.
	StateUninstallPlanning InstallState = "UNINSTALL_PLANNING"

	// StateUninstallReleased is the terminal success state for v1.100
	// PR-23's uninstall mutation (authority release core). Reached
	// after:
	//   - kernel nftban tables flushed + deleted
	//   - nftband.service stopped, disabled, masked
	//   - end-state validation passed (no nftban authority remaining)
	//   - emergency SSH table cleanly removed
	//
	// IsApplyTerminal() returns true for this state so downstream
	// lifecycle consumers see it as a completed apply outcome.
	// ExitCode() maps to ExitCommitted (0) — the operator asked for
	// uninstall and got it. However, the uninstall-history
	// representation is intentionally SKIPPED for this state in PR-23
	// (Option A locked 2026-04-20): update-history.json cannot
	// truthfully represent uninstall success under its install-centric
	// schema, and the separate-schema work is explicitly deferred to a
	// later PR. writeHistory is gated on cfg.mode != "uninstall" in
	// main.go, so this state does NOT produce a history entry.
	StateUninstallReleased InstallState = "UNINSTALL_RELEASED"

	// StateUninstallFailedRelease is the terminal failure state for
	// PR-23 when mutation started but did not complete cleanly. The
	// emergency SSH table may still be present (over-permissive SSH
	// is the deliberate fallback — losing SSH on a failure is a worse
	// outcome than a temporary permissive rule). Operator must
	// investigate kernel + service state and either retry or manually
	// resolve. IsApplyTerminal() returns true; ExitCode() maps to
	// ExitFailed (2).
	StateUninstallFailedRelease InstallState = "UNINSTALL_FAILED_RELEASE"

	// PR-24 authority restoration policy-engine states.
	//
	// These are produced ONLY by the pure decision engine in
	// internal/installer/restore. The engine performs no kernel,
	// service, or filesystem mutation; these states therefore represent
	// a policy outcome, not an apply outcome.
	//
	// StateRestoreRefused is the terminal state produced when the
	// lattice returns REFUSE. It is terminal, NOT failed (refusal is
	// not failure — it is a correct policy outcome), and deliberately
	// excluded from IsApplyTerminal so it does not flow through
	// update-history.json under the install-centric schema. ExitCode()
	// returns ExitRefused (5).
	StateRestoreRefused InstallState = "RESTORE_REFUSED"

	// StateRestoreIntentRequired is the terminal state produced when
	// the lattice returns REQUIRE_EXPLICIT_INTENT. Same discipline as
	// StateRestoreRefused: terminal, not failed, not apply-terminal,
	// not recorded in history. ExitCode() returns ExitIntentRequired
	// (6), distinct from refusal so operators and automation can tell
	// "engine said no" from "engine needs you to clarify".
	StateRestoreIntentRequired InstallState = "RESTORE_INTENT_REQUIRED"

	// StateRestoreDecided is the NON-TERMINAL policy-handoff marker
	// produced when the lattice returns PROCEED. Locked semantics per
	// contract seed §7 (merged as PR #493):
	//
	//   1. Policy-only: records that the decision engine said PROCEED.
	//   2. Non-terminal for apply semantics: IsApplyTerminal() and
	//      IsTerminal() both return false.
	//   3. Excluded from update-history.json: Option A discipline
	//      continues; main.go already gates history on cfg.mode !=
	//      "uninstall" AND state.IsApplyTerminal(). This state will
	//      eventually gain its own mode-guard if --mode=restore ever
	//      writes history; for now, IsApplyTerminal=false closes the
	//      write path defensively.
	//   4. Not evidence that restoration happened: no kernel, service,
	//      or filesystem change is implied. PR-25+ execution would
	//      change state further; in PR-24, PROCEED is a handoff
	//      outcome only.
	//
	// ExitCode() returns ExitCommitted (0) — the operator got the
	// decision they asked for, and the process exit code reflects
	// decision success, not execution success.
	StateRestoreDecided InstallState = "RESTORE_DECIDED"
)

// Phase represents a named installer phase.
type Phase string

const (
	PhaseDetect    Phase = "DETECT"
	PhasePrepare   Phase = "PREPARE"
	PhaseSwitch    Phase = "SWITCH"
	PhaseConfigure Phase = "CONFIGURE"
	PhaseValidate  Phase = "VALIDATE"
	PhaseReport    Phase = "REPORT"
)

// ExitCode is the process exit code contract for nftban-installer.
//
// Contract (frozen):
//
//	0 = COMMITTED        — all phases passed, firewall running and verified
//	1 = DEGRADED         — firewall running but some validation checks failed
//	2 = FAILED           — a critical phase failed, firewall may not be running
//	3 = ABORTED          — conflicting firewalls detected, no --takeover flag
//	4 = FATAL            — unrecoverable error (binary not found, permission denied)
//	5 = REFUSED          — PR-24 restore policy engine: policy forbids restoration
//	6 = INTENT_REQUIRED  — PR-24 restore policy engine: operator must clarify intent
const (
	ExitCommitted      = 0
	ExitDegraded       = 1
	ExitFailed         = 2
	ExitAborted        = 3
	ExitFatal          = 4
	ExitRefused        = 5
	ExitIntentRequired = 6
)

// IsApplyTerminal reports whether a state represents the terminal
// outcome of a real apply operation (install or upgrade). Only these
// states should produce an entry in update-history.json — preview /
// planning / dry-run states must not.
//
// Explicit allowlist, not a default catch-all. PR-22B introduced this
// after the previous audit found that any non-Committed/Degraded state
// was silently mapped to "install_fail" in history — including
// dry-run-terminal states that never attempted mutation.
//
// Consumers that need to distinguish "apply succeeded / apply failed /
// apply was never attempted" must base the decision on IsApplyTerminal
// and NOT on the string value of the state.
func (s InstallState) IsApplyTerminal() bool {
	switch s {
	case StateCommitted,
		StateDegraded,
		StateFailedSSH,
		StateFailedAbort,
		StateFailedRender,
		StateFailedRebuild,
		StateFailedNoFirewall,
		StateFailedTakeover,
		// PR-23: uninstall terminal states represent completed apply
		// outcomes too. IsApplyTerminal participates in the
		// history-write gate, but the uninstall-history Option A lock
		// means main.go's writeHistory call additionally excludes
		// cfg.mode=="uninstall" — so these states here are marked
		// apply-terminal for lifecycle-bridge consumers without
		// triggering install-centric history representation.
		StateUninstallReleased,
		StateUninstallFailedRelease:
		return true
	}
	// PR-24 restore policy-engine states are DELIBERATELY excluded.
	// StateRestoreRefused and StateRestoreIntentRequired are terminal
	// policy outcomes with no mutation; StateRestoreDecided is a
	// non-terminal handoff marker. None of them represent an apply
	// outcome and none should enter update-history.json.
	return false
}

// IsApplyTerminal is a package-level alias for the (InstallState)
// IsApplyTerminal method, kept so consumers that hold the state as a
// plain value can call it symmetrically with the other helpers in this
// file.
func IsApplyTerminal(s InstallState) bool { return s.IsApplyTerminal() }

// IsFailed returns true if the state represents a failure.
//
// PR-24: restore policy-engine terminal states (StateRestoreRefused,
// StateRestoreIntentRequired) are NOT failures — refusal and
// intent-required are correct policy outcomes, not error conditions.
func (s InstallState) IsFailed() bool {
	switch s {
	case StateFailedSSH, StateFailedAbort, StateFailedRender,
		StateFailedRebuild, StateFailedNoFirewall, StateFailedTakeover,
		// PR-23 uninstall failure terminal.
		StateUninstallFailedRelease:
		return true
	}
	return false
}

// IsTerminal returns true if the state is a final state (no further transitions).
//
// PR-24: StateRestoreRefused and StateRestoreIntentRequired are
// terminal; StateRestoreDecided is NOT (it is a policy-handoff marker,
// per contract seed §7).
func (s InstallState) IsTerminal() bool {
	if s == StateCommitted || s == StateDegraded || s.IsFailed() {
		return true
	}
	if s == StateRestoreRefused || s == StateRestoreIntentRequired {
		return true
	}
	return false
}

// ExitCode returns the process exit code for this state.
func (s InstallState) ExitCode() int {
	switch s {
	case StateCommitted:
		return ExitCommitted
	// PR-23: uninstall success maps to ExitCommitted too. The operator
	// asked for uninstall and got it; the process exit code reflects
	// operation success, not install-specific success. Install-history
	// semantics are kept distinct via the writeHistory mode guard.
	case StateUninstallReleased:
		return ExitCommitted
	// PR-24: StateRestoreDecided is the PROCEED handoff. Decision
	// succeeded; exit 0.
	case StateRestoreDecided:
		return ExitCommitted
	// PR-24: distinct exit codes per seed §8 — operators and automation
	// must distinguish "engine said no" from "engine said clarify" from
	// "engine failed".
	case StateRestoreRefused:
		return ExitRefused
	case StateRestoreIntentRequired:
		return ExitIntentRequired
	case StateDegraded:
		return ExitDegraded
	case StateFailedAbort:
		return ExitAborted
	default:
		if s.IsFailed() {
			return ExitFailed
		}
		// Non-terminal states should not produce exit codes, but if asked, treat as failed.
		return ExitFailed
	}
}

// ResumePhase returns the phase to resume from when running in --repair mode.
func (s InstallState) ResumePhase() Phase {
	switch s {
	case StateCommitted:
		return PhaseReport
	case StateDegraded, StateServicesComplete:
		return PhaseValidate
	case StateSwitchComplete:
		return PhaseConfigure
	case StateFailedRebuild, StateFailedNoFirewall, StateFailedTakeover,
		StatePrepareComplete:
		return PhaseSwitch
	case StateFailedRender, StateDetectComplete:
		return PhasePrepare
	default:
		// FILES_INSTALLED, FAILED_SSH_UNKNOWN, FAILED_AUTHORITY_ABORT, or unknown
		return PhaseDetect
	}
}
