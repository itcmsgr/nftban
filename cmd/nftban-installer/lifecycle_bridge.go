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
	"os"
	"time"

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
}

// newLifecycleBridge creates a bridge that writes lifecycle events to stderr.
func newLifecycleBridge(installerMode string, log *logging.Logger) *lifecycleBridge {
	mode := mapInstallerMode(installerMode)

	lb := &lifecycleBridge{
		logger: lifecycle.NewLogger(os.Stderr, mode, false),
		mode:   mode,
	}

	log.Info("lifecycle bridge initialized (mode=%s, observational only)", mode)
	return lb
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
func (lb *lifecycleBridge) observePlan(pd *phaseData) {
	var actions []lifecycle.Action
	switch pd.decision {
	case "takeover":
		actions = []lifecycle.Action{lifecycle.ActionTakeAuthority}
	case "fresh":
		actions = []lifecycle.Action{lifecycle.ActionTakeAuthority}
	case "update":
		actions = []lifecycle.Action{lifecycle.ActionPreserveAuthority}
	case "abort":
		actions = []lifecycle.Action{lifecycle.ActionAbort}
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
func (lb *lifecycleBridge) observeResult(sf *state.StateFile) {
	result := lifecycle.RunResult{
		SchemaVersion: lifecycle.OutputSchemaVersion,
		Mode:          lb.mode,
		DryRun:        false,
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
func mapAuthority(decision string) lifecycle.AuthorityOwner {
	switch decision {
	case "takeover":
		return lifecycle.AuthorityExternal // was external, taking over
	case "fresh":
		return lifecycle.AuthorityNone
	case "update":
		return lifecycle.AuthorityNFTBan
	case "abort":
		return lifecycle.AuthorityExternal
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
