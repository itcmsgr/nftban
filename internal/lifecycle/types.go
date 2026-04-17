// =============================================================================
// NFTBan v1.97 - Lifecycle Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-types"
// meta:type="lib"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Type definitions for lifecycle orchestration: stages, outcomes, authority, detection"
// meta:inventory.files="internal/lifecycle/types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V197_LIFECYCLE_CONTRACT.md
// Invariants: INV-LC-001 through INV-LC-008
//
// Architecture:
//   Lifecycle is an ORCHESTRATION layer. It plans and describes.
//   It is NOT a truth source. Validator is truth. Kernel is authority.
//   v1.96 rebuild/recovery provides ground-truth operation results.
//   Lifecycle consumes those results — it never redefines them.
// =============================================================================

package lifecycle

import "time"

// =============================================================================
// Stages — phases of lifecycle execution
// =============================================================================

// Stage represents a phase in the lifecycle execution pipeline.
// Stages are sequential: DETECT → PLAN → APPLY → VERIFY → FINAL.
type Stage string

const (
	StageDetect Stage = "DETECT"
	StagePlan   Stage = "PLAN"
	StageApply  Stage = "APPLY"
	StageVerify Stage = "VERIFY"
	StageFinal  Stage = "FINAL"
)

// =============================================================================
// Outcomes — results of lifecycle execution
// =============================================================================

// Outcome represents the high-level result of a lifecycle operation.
//
// Lifecycle Outcome is a high-level orchestration result. Detailed failure
// semantics remain in v1.96 operation result and failure class fields
// (rebuild.OperationResult, rebuild.FailureClass). Do not conflate
// lifecycle FAILED with rebuild FAILED_DEGRADED or FAILED_FATAL —
// those are distinct levels of specificity.
type Outcome string

const (
	// OutcomeSuccess means all stages completed and verification passed.
	OutcomeSuccess Outcome = "SUCCESS"

	// OutcomeFailed means execution failed with no recovery.
	// For detailed failure class, see LastOperation.FailureClass.
	OutcomeFailed Outcome = "FAILED"

	// OutcomeFailedRecovered means execution failed but recovery
	// restored a validated prior state. System may be healthy
	// even though the operation did not achieve its goal.
	OutcomeFailedRecovered Outcome = "FAILED_RECOVERED"
)

// =============================================================================
// Modes — types of lifecycle operation
// =============================================================================

// Mode represents the type of lifecycle operation being performed.
type Mode string

const (
	ModeInstall     Mode = "install"
	ModeUpdate      Mode = "update"
	ModeUninstall   Mode = "uninstall"
	ModeMaintenance Mode = "maintenance"
)

// ValidMode returns true if m is a recognized lifecycle mode.
func ValidMode(m Mode) bool {
	switch m {
	case ModeInstall, ModeUpdate, ModeUninstall, ModeMaintenance:
		return true
	}
	return false
}

// =============================================================================
// Authority — who controls the firewall and in what state
// =============================================================================

// AuthorityOwner identifies who currently controls the firewall.
type AuthorityOwner string

const (
	// AuthorityNFTBan means NFTBan owns the firewall authority.
	// This is valid even when health is DEGRADED — ownership and
	// health are independent dimensions (INV-LC-004).
	AuthorityNFTBan AuthorityOwner = "NFTBAN"

	// AuthorityExternal means another firewall (CSF, UFW, firewalld)
	// controls the system. Lifecycle may observe but MUST NOT seize
	// authority without explicit operator instruction.
	AuthorityExternal AuthorityOwner = "EXTERNAL"

	// AuthorityNone means no managed firewall authority exists.
	// Health should normally be DOWN when owner is NONE.
	AuthorityNone AuthorityOwner = "NONE"
)

// LifecycleHealth represents the health dimension of authority.
// These values mirror validator.Status but are defined here to avoid
// import cycles. The lifecycle engine consumes health from the validator
// and maps it to these values.
type LifecycleHealth string

const (
	HealthProtected LifecycleHealth = "PROTECTED"
	HealthIdle      LifecycleHealth = "IDLE"
	HealthDegraded  LifecycleHealth = "DEGRADED"
	HealthDown      LifecycleHealth = "DOWN"
)

// AuthorityState combines ownership and health into a single assessment.
// These are INDEPENDENT dimensions — NFTBAN + DEGRADED is a valid state
// meaning "NFTBan owns the firewall but protection is partial."
type AuthorityState struct {
	Owner  AuthorityOwner  `json:"owner"`
	Health LifecycleHealth `json:"health"`
}

// IsOwned returns true if NFTBan has authority (regardless of health).
func (a AuthorityState) IsOwned() bool {
	return a.Owner == AuthorityNFTBan
}

// IsHealthy returns true if health is PROTECTED or IDLE.
func (a AuthorityState) IsHealthy() bool {
	return a.Health == HealthProtected || a.Health == HealthIdle
}

// NormalizeNone ensures that Owner=NONE has health=DOWN unless
// there is a specific reason otherwise. This prevents confusing
// states like NONE + PROTECTED.
func (a *AuthorityState) NormalizeNone() {
	if a.Owner == AuthorityNone && a.Health != HealthDown {
		a.Health = HealthDown
	}
}

// =============================================================================
// Actions — what the lifecycle engine recommends
// =============================================================================

// Action represents a lifecycle recommendation or decision.
type Action string

const (
	// ActionNoop means no action needed — current state is acceptable.
	ActionNoop Action = "NOOP"

	// ActionTakeAuthority means lifecycle should take firewall ownership.
	ActionTakeAuthority Action = "TAKE_AUTHORITY"

	// ActionPreserveAuthority means keep current NFTBan ownership.
	ActionPreserveAuthority Action = "PRESERVE_AUTHORITY"

	// ActionAbort means lifecycle cannot proceed safely.
	ActionAbort Action = "ABORT"

	// ActionNeedsRecovery means v1.96 recovery must complete first.
	ActionNeedsRecovery Action = "NEEDS_RECOVERY"
)

// =============================================================================
// Detection — what was observed about the system
// =============================================================================

// Detection captures system observations during the DETECT stage.
type Detection struct {
	// ConflictingFirewall is true if another firewall (CSF/UFW/firewalld) is active.
	ConflictingFirewall bool `json:"conflicting_firewall"`

	// KernelValid is true if nftables kernel state passes structural checks.
	KernelValid bool `json:"kernel_valid"`

	// ValidatorConsistent is true if validator agrees with kernel state.
	ValidatorConsistent bool `json:"validator_consistent"`

	// SSHSafe is true if SSH port is protected and accessible.
	SSHSafe bool `json:"ssh_safe"`
}

// =============================================================================
// LastOperation — v1.96 ground truth (consumed, not redefined)
// =============================================================================

// LastOperation carries v1.96 operation-result truth into lifecycle output.
// Lifecycle MUST consume these values from rebuild.RecoveryMarker and
// validator state — it MUST NOT reinterpret or override them (INV-LC-003).
type LastOperation struct {
	// Result is the v1.96 operation result (SUCCESS, FAILED_RECOVERED, etc.)
	Result string `json:"result"`

	// FailureClass is the v1.96 failure classification (if non-success).
	FailureClass string `json:"failure_class"`

	// RecoveryPending is true if a v1.96 recovery marker exists and is not exhausted.
	RecoveryPending bool `json:"recovery_pending"`

	// LastRebuildFailed is true if the most recent rebuild was non-success.
	// This flag exists for dashboard clarity: health=PROTECTED + last_rebuild_failed=true
	// means "healthy now but just recovered from failure."
	LastRebuildFailed bool `json:"last_rebuild_failed"`
}

// =============================================================================
// Plan — what the engine recommends
// =============================================================================

// Plan captures the engine's recommended actions, warnings, and errors.
type Plan struct {
	Actions  []Action `json:"actions"`
	Warnings []string `json:"warnings"`
	Errors   []string `json:"errors"`
}

// HasAbort returns true if the plan contains an ABORT action.
func (p Plan) HasAbort() bool {
	for _, a := range p.Actions {
		if a == ActionAbort {
			return true
		}
	}
	return false
}

// HasRecovery returns true if the plan requires v1.96 recovery first.
func (p Plan) HasRecovery() bool {
	for _, a := range p.Actions {
		if a == ActionNeedsRecovery {
			return true
		}
	}
	return false
}

// =============================================================================
// Snapshot — engine input (current system state)
// =============================================================================

// Snapshot captures the current system state as input to the lifecycle engine.
// All fields must be populated from real system observations (validator,
// recovery marker, service state, conflict detection) — never guessed.
type Snapshot struct {
	// Mode is the requested lifecycle operation.
	Mode Mode `json:"mode"`

	// DryRun is true if this is a planning-only run (INV-LC-001).
	DryRun bool `json:"dry_run"`

	// CurrentAuthority is the observed authority state.
	CurrentAuthority AuthorityState `json:"current_authority"`

	// LastOperation carries v1.96 operation-result ground truth.
	LastOperation LastOperation `json:"last_operation"`

	// Detection carries system observations from the DETECT stage.
	Detection Detection `json:"detection"`
}

// =============================================================================
// RunResult — engine output
// =============================================================================

// RunResult is the complete output of a lifecycle engine run.
// It represents a PLAN, not an execution result (in v1.97).
type RunResult struct {
	// SchemaVersion for output stability.
	SchemaVersion string `json:"schema_version"`

	// Mode that was requested.
	Mode Mode `json:"mode"`

	// DryRun indicates this was a planning-only run.
	DryRun bool `json:"dry_run"`

	// Stage reached during execution/planning.
	Stage Stage `json:"stage"`

	// Outcome of the lifecycle operation.
	Outcome Outcome `json:"outcome"`

	// Authority shows prior, desired, and resulting authority states.
	Authority struct {
		Prior     AuthorityState `json:"prior"`
		Desired   AuthorityState `json:"desired"`
		Resulting AuthorityState `json:"resulting"`
	} `json:"authority"`

	// LastOperation from v1.96 (passed through, not reinterpreted).
	LastOperation LastOperation `json:"last_operation"`

	// Plan contains recommended actions, warnings, and errors.
	Plan Plan `json:"plan"`

	// Detection from the DETECT stage.
	Detection Detection `json:"detection"`

	// Timestamp of when the result was produced.
	Timestamp time.Time `json:"timestamp"`
}

// OutputSchemaVersion is the current version of the lifecycle JSON schema.
const OutputSchemaVersion = "1.0"
