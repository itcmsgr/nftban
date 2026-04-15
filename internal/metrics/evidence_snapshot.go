// =============================================================================
// NFTBan v1.87 - Evidence Snapshot Builder + Renderers (M87-7/8)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_snapshot"
// meta:type="package"
// meta:version="1.87.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Builds and renders Phase 1 evidence snapshots"
// meta:inventory.files="internal/metrics/evidence_snapshot.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// Collect once → render many.
// Metrics report evidence; validator reports interpretation.
// =============================================================================
package metrics

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"time"
)

// EvidenceSnapshot is the canonical Phase 1 metrics model.
// Collected once, rendered as JSON or human-readable text.
//
// This is NOT a truth object. Validator remains sole authority.
// Correlation is diagnostic only — cannot affect exit codes.
type EvidenceSnapshot struct {
	SchemaVersion  string                  `json:"schema_version"`
	CollectedAt    time.Time               `json:"collected_at"`
	TruthAuthority string                  `json:"truth_authority"`

	Kernel struct {
		Counters map[string]CounterValue `json:"counters"`
		Sets     map[string]SetInfo      `json:"sets"`
		Chains   map[string]ChainInfo    `json:"chains"`
	} `json:"kernel"`

	Validator *ValidatorSnapshot   `json:"validator"`
	Correlation map[string]string  `json:"correlation"`
}

const EvidenceSchemaVersion = "1.87.0"

// CollectEvidenceSnapshot gathers all Phase 1 evidence.
// Single entry point: collect once, render many.
func CollectEvidenceSnapshot(ctx context.Context) (*EvidenceSnapshot, error) {
	snap := &EvidenceSnapshot{
		SchemaVersion:  EvidenceSchemaVersion,
		CollectedAt:    time.Now(),
		TruthAuthority: "kernel",
	}

	// Kernel plane
	// Counter collection failure → nil (not empty map).
	// nil signals "unknown/unavailable" to correlation and renderer.
	// Empty map signals "collected successfully, no active counters."
	counters, err := CollectNamedCounters(ctx)
	if err != nil {
		snap.Kernel.Counters = nil // collection failed — unknown
	} else {
		snap.Kernel.Counters = counters.Counters
	}

	snap.Kernel.Sets = CollectSetElements(ctx)
	snap.Kernel.Chains = CollectChainPresence(ctx)

	// Validator plane
	snap.Validator = CollectValidatorSnapshot(ctx)

	// Correlation plane
	snap.Correlation = CorrelateEvidence(snap.Kernel.Counters, snap.Kernel.Sets, snap.Validator)

	return snap, nil
}

// =============================================================================
// M87-7: JSON Renderer
// =============================================================================

// RenderJSON serializes the snapshot as canonical Phase 1 JSON.
func RenderJSON(snap *EvidenceSnapshot) ([]byte, error) {
	return json.MarshalIndent(snap, "", "  ")
}

// =============================================================================
// M87-8: Human Renderer
// =============================================================================

// RenderHuman writes operator-first human-readable output.
func RenderHuman(snap *EvidenceSnapshot, w io.Writer) {
	fmt.Fprintf(w, "NFTBan Metrics — Evidence Summary\n")
	fmt.Fprintf(w, "\n")
	fmt.Fprintf(w, "Truth authority: %s\n", snap.TruthAuthority)
	fmt.Fprintf(w, "Collected at:    %s\n", snap.CollectedAt.UTC().Format("2006-01-02T15:04:05Z"))

	// Validator status
	if snap.Validator != nil && !snap.Validator.Unknown {
		fmt.Fprintf(w, "Validator:       %s\n", snap.Validator.Status)
	} else {
		fmt.Fprintf(w, "Validator:       unavailable\n")
	}
	fmt.Fprintf(w, "\n")

	// Enforcement counters
	fmt.Fprintf(w, "Enforcement Evidence\n")
	fmt.Fprintf(w, "────────────────────────────────────────\n")
	if snap.Kernel.Counters == nil {
		// Collection failed — unknown, not "no evidence"
		fmt.Fprintf(w, "  (counter evidence unavailable)\n")
	} else {
		enforcementKeys := []string{
			"ip:input_ct_ssh_drop", "ip:input_ct_http_drop", "ip:input_ct_mail_drop",
			"ip:input_syn_rate_exceeded", "ip6:input_syn_prefix_drop",
			"ip:input_blacklist_manual_drop", "ip:input_blacklist_drop",
		}
		anyEnforcement := false
		for _, key := range enforcementKeys {
			if cv, ok := snap.Kernel.Counters[key]; ok && cv.Packets > 0 {
				fmt.Fprintf(w, "  %-38s %d packets\n", key, cv.Packets)
				anyEnforcement = true
			}
		}
		if !anyEnforcement {
			fmt.Fprintf(w, "  (no enforcement counters active)\n")
		}
	}
	fmt.Fprintf(w, "\n")

	// BotGuard sets (non-zero)
	fmt.Fprintf(w, "BotGuard Sets\n")
	fmt.Fprintf(w, "────────────────────────────────────────\n")
	bgKeys := []string{
		"ip:http_bot_suspect", "ip:http_bot_pending", "ip:http_bot_allow",
		"ip:http_bot_grey", "ip:http_bot_ban", "ip:http_bot_emergency",
	}
	anyBG := false
	for _, key := range bgKeys {
		if si, ok := snap.Kernel.Sets[key]; ok {
			if si.Unknown {
				fmt.Fprintf(w, "  %-38s unknown\n", key)
				anyBG = true
			} else if si.Exists {
				fmt.Fprintf(w, "  %-38s %d elements\n", key, si.Count)
				anyBG = true
			}
		}
	}
	if !anyBG {
		fmt.Fprintf(w, "  (not present)\n")
	}
	fmt.Fprintf(w, "\n")

	// Correlation
	fmt.Fprintf(w, "Correlation\n")
	fmt.Fprintf(w, "────────────────────────────────────────\n")
	modules := make([]string, 0, len(snap.Correlation))
	for mod := range snap.Correlation {
		modules = append(modules, mod)
	}
	sort.Strings(modules)
	for _, mod := range modules {
		result := snap.Correlation[mod]
		fmt.Fprintf(w, "  %-20s %s\n", mod, result)
	}
	fmt.Fprintf(w, "\n")

	// Findings
	if snap.Validator != nil && len(snap.Validator.Findings) > 0 {
		fmt.Fprintf(w, "Validator Findings\n")
		fmt.Fprintf(w, "────────────────────────────────────────\n")
		for _, code := range snap.Validator.Findings {
			fmt.Fprintf(w, "  %s\n", code)
		}
		fmt.Fprintf(w, "\n")
	}

	// Notes
	fmt.Fprintf(w, "Notes\n")
	fmt.Fprintf(w, "────────────────────────────────────────\n")
	fmt.Fprintf(w, "  - Zero counters are neutral, not failure.\n")
	fmt.Fprintf(w, "  - Shared counters are family-level only; no source attribution.\n")
	fmt.Fprintf(w, "  - Portscan has no dedicated enforcement counter.\n")
	fmt.Fprintf(w, "  - Correlation is diagnostic only — does not determine protection state.\n")
}
