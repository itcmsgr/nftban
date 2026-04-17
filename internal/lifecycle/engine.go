// =============================================================================
// NFTBan v1.97 - Lifecycle State Machine Engine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-engine"
// meta:type="lib"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Pure state machine engine — input snapshot, output plan. No side effects."
// meta:inventory.files="internal/lifecycle/engine.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V197_LIFECYCLE_CONTRACT.md
// INV-LC-001: Engine MUST NOT mutate system state.
// INV-LC-002: Engine is NOT a truth source. It plans based on observed state.
// INV-LC-003: v1.96 operation results are consumed, never redefined.
// INV-LC-008: FAILED_RECOVERED + PROTECTED is preserved as two distinct truths.
// =============================================================================

package lifecycle

import "time"

// Run executes the lifecycle state machine against a snapshot.
// It is a PURE function — no side effects, no system mutation (INV-LC-001).
// The engine consumes observed state and produces a plan.
func Run(snap Snapshot) RunResult {
	result := RunResult{
		SchemaVersion: OutputSchemaVersion,
		Mode:          snap.Mode,
		DryRun:        snap.DryRun,
		Detection:     snap.Detection,
		LastOperation:  snap.LastOperation,
		Timestamp:     time.Now(),
	}

	// Set authority prior from snapshot
	result.Authority.Prior = snap.CurrentAuthority

	// Desired authority depends on mode
	result.Authority.Desired = desiredAuthority(snap.Mode)

	// ─── DETECT stage ───────────────────────────────────────────────────
	result.Stage = StageDetect

	// Check: conflicting firewall blocks NFTBan authority
	if snap.Detection.ConflictingFirewall && result.Authority.Desired.Owner == AuthorityNFTBan {
		result.Stage = StageDetect
		result.Outcome = OutcomeFailed
		result.Plan.Actions = []Action{ActionAbort}
		result.Plan.Errors = append(result.Plan.Errors,
			"conflicting firewall active — cannot take NFTBan authority")
		result.Authority.Resulting = snap.CurrentAuthority
		return result
	}

	// Check: v1.96 recovery pending — must resolve before new lifecycle operation
	if snap.LastOperation.RecoveryPending {
		result.Stage = StageDetect
		result.Outcome = OutcomeFailed
		result.Plan.Actions = []Action{ActionNeedsRecovery}
		result.Plan.Errors = append(result.Plan.Errors,
			"v1.96 recovery pending — resolve before lifecycle operation")
		result.Authority.Resulting = snap.CurrentAuthority
		return result
	}

	// Check: mode validity
	if !ValidMode(snap.Mode) {
		result.Stage = StageDetect
		result.Outcome = OutcomeFailed
		result.Plan.Actions = []Action{ActionAbort}
		result.Plan.Errors = append(result.Plan.Errors,
			"invalid lifecycle mode: "+string(snap.Mode))
		result.Authority.Resulting = snap.CurrentAuthority
		return result
	}

	// ─── PLAN stage ─────────────────────────────────────────────────────
	result.Stage = StagePlan

	action, warnings := resolveAction(snap)
	result.Plan.Actions = []Action{action}
	result.Plan.Warnings = warnings

	// Check: action is ABORT
	if action == ActionAbort {
		result.Outcome = OutcomeFailed
		result.Authority.Resulting = snap.CurrentAuthority
		return result
	}

	// Check: action requires recovery first
	if action == ActionNeedsRecovery {
		result.Outcome = OutcomeFailed
		result.Authority.Resulting = snap.CurrentAuthority
		return result
	}

	// ─── In v1.97, dry-run stops here (INV-LC-001) ──────────────────────
	// APPLY and VERIFY stages are planned but not executed.
	result.Stage = StageFinal

	// Determine resulting authority
	switch action {
	case ActionTakeAuthority:
		result.Authority.Resulting = result.Authority.Desired
	case ActionPreserveAuthority, ActionNoop:
		result.Authority.Resulting = snap.CurrentAuthority
	default:
		result.Authority.Resulting = snap.CurrentAuthority
	}

	// Determine outcome based on resulting authority, not prior
	// For TAKE_AUTHORITY (fresh install), resulting is the target state
	// INV-LC-008: preserve two truths if last rebuild failed but recovered
	if snap.LastOperation.LastRebuildFailed && snap.CurrentAuthority.IsHealthy() {
		result.Outcome = OutcomeSuccess
		result.Plan.Warnings = append(result.Plan.Warnings,
			"last rebuild failed but rollback restored service — both truths preserved")
	} else if action == ActionTakeAuthority {
		// Taking authority = plan to reach desired state (SUCCESS as a plan)
		result.Outcome = OutcomeSuccess
	} else if snap.CurrentAuthority.Health == HealthDown {
		result.Outcome = OutcomeFailed
	} else {
		result.Outcome = OutcomeSuccess
	}

	return result
}

// desiredAuthority returns the target authority state for a given mode.
func desiredAuthority(mode Mode) AuthorityState {
	switch mode {
	case ModeInstall:
		return AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	case ModeUpdate:
		return AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	case ModeUninstall:
		return AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	case ModeMaintenance:
		// Maintenance preserves current authority
		return AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	default:
		return AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	}
}

// resolveAction determines the appropriate action based on current state.
func resolveAction(snap Snapshot) (Action, []string) {
	var warnings []string
	prior := snap.CurrentAuthority

	switch snap.Mode {
	case ModeInstall:
		return resolveInstallAction(prior, snap, &warnings), warnings
	case ModeUpdate:
		return resolveUpdateAction(prior, snap, &warnings), warnings
	case ModeUninstall:
		return resolveUninstallAction(prior, &warnings), warnings
	case ModeMaintenance:
		return resolveMaintenanceAction(prior, snap, &warnings), warnings
	default:
		return ActionAbort, append(warnings, "unknown mode")
	}
}

func resolveInstallAction(prior AuthorityState, snap Snapshot, warnings *[]string) Action {
	switch prior.Owner {
	case AuthorityNone:
		// No existing authority — safe to take
		return ActionTakeAuthority

	case AuthorityExternal:
		// External firewall — abort unless explicit takeover
		*warnings = append(*warnings, "external firewall detected — will not override without explicit takeover")
		return ActionAbort

	case AuthorityNFTBan:
		// Already owned — this is a reinstall
		if prior.Health == HealthDegraded {
			*warnings = append(*warnings, "existing NFTBan installation is degraded — reinstall may fix")
		}
		if prior.Health == HealthDown {
			*warnings = append(*warnings, "existing NFTBan installation is down — reinstall recommended")
		}
		return ActionPreserveAuthority
	}
	return ActionAbort
}

func resolveUpdateAction(prior AuthorityState, snap Snapshot, warnings *[]string) Action {
	if prior.Owner != AuthorityNFTBan {
		*warnings = append(*warnings, "cannot update — NFTBan does not own firewall authority")
		return ActionAbort
	}

	if prior.Health == HealthDown {
		*warnings = append(*warnings, "NFTBan is DOWN — update may not succeed, consider recovery first")
		return ActionNeedsRecovery
	}

	if prior.Health == HealthDegraded {
		*warnings = append(*warnings, "NFTBan is DEGRADED — update will proceed with caution")
	}

	return ActionPreserveAuthority
}

func resolveUninstallAction(prior AuthorityState, warnings *[]string) Action {
	if prior.Owner == AuthorityNone {
		*warnings = append(*warnings, "no authority to release — nothing to uninstall")
		return ActionNoop
	}

	if prior.Owner == AuthorityExternal {
		*warnings = append(*warnings, "external firewall — NFTBan components may be removed but authority is not NFTBan's")
	}

	// Release authority
	return ActionTakeAuthority // semantically: release authority to NONE
}

func resolveMaintenanceAction(prior AuthorityState, snap Snapshot, warnings *[]string) Action {
	if prior.Owner != AuthorityNFTBan {
		*warnings = append(*warnings, "cannot perform maintenance — NFTBan does not own authority")
		return ActionAbort
	}

	if prior.Health == HealthDown {
		*warnings = append(*warnings, "NFTBan is DOWN — maintenance cannot proceed")
		return ActionNeedsRecovery
	}

	return ActionPreserveAuthority
}
