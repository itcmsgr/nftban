// =============================================================================
// NFTBan v1.88 - Validator Snapshot Bridge (M87-5)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_validator"
// meta:type="package"
// meta:version="1.88.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Read-only bridge to validator JSON for metrics evidence"
// meta:inventory.files="internal/metrics/evidence_validator.go"
// meta:inventory.binaries="nftban-validate"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// Read-only bridge: calls nftban-validate --json once and extracts
// status, module effective states, and finding codes.
// Metrics MUST NOT modify validator truth. This is observation only.
// =============================================================================
package metrics

import (
	"context"
	"encoding/json"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/procenv"
)

// ValidatorSnapshot holds extracted validator state for metrics enrichment.
// This is NOT a truth object — it is a read-only observation of validator output.
// Metrics cannot modify, override, or reinterpret these values.
type ValidatorSnapshot struct {
	Status   string            `json:"status"`            // protected/idle/degraded/down/unavailable
	Modules  map[string]string `json:"modules"`           // module → effective state
	Findings []string          `json:"findings"`          // finding codes only
	Unknown  bool              `json:"unknown,omitempty"` // true if collection failed
}

// ValidatorBinPath is the validator binary path.
// Uses the canonical constant from internal/constants. Configurable for testing.
var ValidatorBinPath = constants.ValidatorBinPath

// CollectValidatorSnapshot calls nftban-validate --json and extracts
// status, module states, and finding codes.
// Returns ValidatorSnapshot with Unknown=true on any failure.
//
// DEPRECATED (v1.89): CollectEvidenceSnapshot now calls validator.ValidateKernel()
// directly and uses buildValidatorSnapshot() for richer extraction. This function
// is retained for any standalone callers but is no longer on the evidence hot path.
func CollectValidatorSnapshot(ctx context.Context) *ValidatorSnapshot {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	output, err := runValidator(ctx)
	if err != nil {
		return &ValidatorSnapshot{Status: "unavailable", Unknown: true}
	}

	return parseValidatorJSON(output)
}

// runValidator executes the validator binary.
func runValidator(ctx context.Context) ([]byte, error) {
	return procenv.CommandContext(ctx, ValidatorBinPath, "--json").Output() // #nosec G204 -- fixed binary path
}

// parseValidatorJSON extracts metrics-relevant fields from validator JSON.
// Package-internal; testable via fixture inputs in evidence_validator_test.go.
func parseValidatorJSON(data []byte) *ValidatorSnapshot {
	var val struct {
		Status  string `json:"status"`
		Modules struct {
			BotGuard *struct {
				Effective string `json:"effective"`
			} `json:"botguard,omitempty"`
			DDoS *struct {
				Effective string `json:"effective"`
			} `json:"ddos,omitempty"`
			Portscan *struct {
				Effective string `json:"effective"`
			} `json:"portscan,omitempty"`
			LoginMon *struct {
				Effective string `json:"effective"`
			} `json:"loginmon,omitempty"`
			Blacklist *struct {
				Manual struct {
					State string `json:"state"`
				} `json:"manual"`
				Feeds struct {
					State string `json:"state"`
				} `json:"feeds"`
				Geoban struct {
					State string `json:"state"`
				} `json:"geoban"`
			} `json:"blacklist,omitempty"`
		} `json:"modules"`
		Findings []struct {
			Code string `json:"code"`
		} `json:"findings"`
	}

	if err := json.Unmarshal(data, &val); err != nil {
		return &ValidatorSnapshot{Status: "unavailable", Unknown: true}
	}

	// Status is required for a valid snapshot. If missing, the validator
	// output is structurally incomplete and cannot be trusted.
	if val.Status == "" {
		return &ValidatorSnapshot{Status: "unavailable", Unknown: true}
	}

	snap := &ValidatorSnapshot{
		Status:  val.Status,
		Modules: make(map[string]string),
	}

	if val.Modules.DDoS != nil {
		snap.Modules["ddos"] = val.Modules.DDoS.Effective
	}
	if val.Modules.BotGuard != nil {
		snap.Modules["botguard"] = val.Modules.BotGuard.Effective
	}
	if val.Modules.Portscan != nil {
		snap.Modules["portscan"] = val.Modules.Portscan.Effective
	}
	if val.Modules.LoginMon != nil {
		snap.Modules["loginmon"] = val.Modules.LoginMon.Effective
	}
	if val.Modules.Blacklist != nil {
		snap.Modules["blacklist_manual"] = val.Modules.Blacklist.Manual.State
		snap.Modules["blacklist_feeds"] = val.Modules.Blacklist.Feeds.State
		snap.Modules["blacklist_geoban"] = val.Modules.Blacklist.Geoban.State
	}

	for _, f := range val.Findings {
		snap.Findings = append(snap.Findings, f.Code)
	}

	return snap
}
