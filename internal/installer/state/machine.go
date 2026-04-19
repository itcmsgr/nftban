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
//	0 = COMMITTED  — all phases passed, firewall running and verified
//	1 = DEGRADED   — firewall running but some validation checks failed
//	2 = FAILED     — a critical phase failed, firewall may not be running
//	3 = ABORTED    — conflicting firewalls detected, no --takeover flag
//	4 = FATAL      — unrecoverable error (binary not found, permission denied)
const (
	ExitCommitted = 0
	ExitDegraded  = 1
	ExitFailed    = 2
	ExitAborted   = 3
	ExitFatal     = 4
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
		StateFailedTakeover:
		return true
	}
	return false
}

// IsApplyTerminal is a package-level alias for the (InstallState)
// IsApplyTerminal method, kept so consumers that hold the state as a
// plain value can call it symmetrically with the other helpers in this
// file.
func IsApplyTerminal(s InstallState) bool { return s.IsApplyTerminal() }

// IsFailed returns true if the state represents a failure.
func (s InstallState) IsFailed() bool {
	switch s {
	case StateFailedSSH, StateFailedAbort, StateFailedRender,
		StateFailedRebuild, StateFailedNoFirewall, StateFailedTakeover:
		return true
	}
	return false
}

// IsTerminal returns true if the state is a final state (no further transitions).
func (s InstallState) IsTerminal() bool {
	return s == StateCommitted || s == StateDegraded || s.IsFailed()
}

// ExitCode returns the process exit code for this state.
func (s InstallState) ExitCode() int {
	switch s {
	case StateCommitted:
		return ExitCommitted
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
