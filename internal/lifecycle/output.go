// =============================================================================
// NFTBan v1.97 - Lifecycle JSON Output
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-output"
// meta:type="lib"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Stable JSON output rendering for lifecycle engine results"
// meta:inventory.files="internal/lifecycle/output.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V197_LIFECYCLE_CONTRACT.md §4, §6 PR-04
// INV-LC-003: v1.96 operation results are consumed, never redefined.
// INV-LC-006: Output schema is stable, versioned, and additive-only.
// INV-LC-008: FAILED_RECOVERED + PROTECTED preserved as two truths.
// =============================================================================

package lifecycle

import (
	"encoding/json"
	"fmt"
	"io"
)

// RenderJSON writes the RunResult as stable, versioned JSON.
// Schema version is always set to OutputSchemaVersion.
// Fields are ordered for readability and stability.
func RenderJSON(w io.Writer, result RunResult) error {
	result.SchemaVersion = OutputSchemaVersion

	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal lifecycle result: %w", err)
	}

	_, err = w.Write(data)
	if err != nil {
		return fmt.Errorf("write lifecycle result: %w", err)
	}

	_, _ = w.Write([]byte("\n"))
	return nil
}

// RenderText writes a human-readable summary of the RunResult.
func RenderText(w io.Writer, result RunResult) error {
	// Header
	fmt.Fprintf(w, "Lifecycle %s (%s)\n", result.Mode, modeLabel(result.Mode))
	if result.DryRun {
		fmt.Fprintf(w, "  Mode: DRY-RUN (no changes applied)\n")
	}
	fmt.Fprintf(w, "\n")

	// Authority
	fmt.Fprintf(w, "Authority\n")
	fmt.Fprintf(w, "  Prior:     %s / %s\n", result.Authority.Prior.Owner, result.Authority.Prior.Health)
	fmt.Fprintf(w, "  Desired:   %s / %s\n", result.Authority.Desired.Owner, result.Authority.Desired.Health)
	fmt.Fprintf(w, "  Resulting: %s / %s\n", result.Authority.Resulting.Owner, result.Authority.Resulting.Health)
	fmt.Fprintf(w, "\n")

	// Detection
	fmt.Fprintf(w, "Detection\n")
	fmt.Fprintf(w, "  Conflicting firewall: %s\n", boolStatus(result.Detection.ConflictingFirewall, true))
	fmt.Fprintf(w, "  Kernel valid:         %s\n", boolStatus(result.Detection.KernelValid, false))
	fmt.Fprintf(w, "  Validator consistent: %s\n", boolStatus(result.Detection.ValidatorConsistent, false))
	fmt.Fprintf(w, "  SSH safe:             %s\n", boolStatus(result.Detection.SSHSafe, false))
	fmt.Fprintf(w, "\n")

	// Last operation (v1.96 truth)
	if result.LastOperation.Result != "" {
		fmt.Fprintf(w, "Last Operation (v1.96)\n")
		fmt.Fprintf(w, "  Result:           %s\n", result.LastOperation.Result)
		if result.LastOperation.FailureClass != "" {
			fmt.Fprintf(w, "  Failure class:    %s\n", result.LastOperation.FailureClass)
		}
		fmt.Fprintf(w, "  Recovery pending: %v\n", result.LastOperation.RecoveryPending)
		fmt.Fprintf(w, "  Last rebuild failed: %v\n", result.LastOperation.LastRebuildFailed)
		fmt.Fprintf(w, "\n")
	}

	// Plan
	fmt.Fprintf(w, "Plan\n")
	for _, a := range result.Plan.Actions {
		fmt.Fprintf(w, "  Action: %s\n", a)
	}
	for _, warn := range result.Plan.Warnings {
		fmt.Fprintf(w, "  Warning: %s\n", warn)
	}
	for _, e := range result.Plan.Errors {
		fmt.Fprintf(w, "  Error: %s\n", e)
	}
	fmt.Fprintf(w, "\n")

	// Outcome
	fmt.Fprintf(w, "Outcome: %s\n", result.Outcome)
	fmt.Fprintf(w, "Stage:   %s\n", result.Stage)

	return nil
}

// ParseRunResult deserializes a RunResult from JSON.
func ParseRunResult(data []byte) (*RunResult, error) {
	var r RunResult
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("parse lifecycle result: %w", err)
	}
	return &r, nil
}

func modeLabel(m Mode) string {
	switch m {
	case ModeInstall:
		return "Fresh Installation"
	case ModeUpdate:
		return "Upgrade"
	case ModeUninstall:
		return "Removal"
	case ModeMaintenance:
		return "Maintenance"
	default:
		return string(m)
	}
}

func boolStatus(val bool, invertMeaning bool) string {
	if invertMeaning {
		// For "conflicting firewall": true=bad, false=good
		if val {
			return "YES (blocking)"
		}
		return "no"
	}
	// For "kernel valid": true=good, false=bad
	if val {
		return "yes"
	}
	return "NO"
}
