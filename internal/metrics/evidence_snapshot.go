// =============================================================================
// NFTBan v1.89 - Evidence Snapshot Builder + Renderers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_snapshot"
// meta:type="package"
// meta:version="1.89.0"
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
// v1.89 INV-M-001/002: Evidence layer makes ZERO direct nft calls.
// All kernel data (counters, sets, chains) comes from the validator,
// which is the sole kernel-query authority.
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

	"github.com/itcmsgr/nftban/internal/validator"
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

	// v1.88: External evidence plane
	External  *JournalEvidenceResult `json:"external,omitempty"`
	Freshness *DataFreshnessResult   `json:"freshness,omitempty"`

	Validator *ValidatorSnapshot   `json:"validator"`
	Correlation map[string]string  `json:"correlation"`
}

const EvidenceSchemaVersion = "1.88.0"

// CollectEvidenceSnapshot gathers all Phase 1 evidence.
// Single entry point: collect once, render many.
//
// v1.89 INV-M-001/002: All kernel data from validator — ZERO direct nft calls.
// The validator runs nft -j list ruleset (once) + per-set element queries.
// Evidence extracts counters, chains, and set element counts from the
// validator's result. Journal and data freshness are independent sources.
func CollectEvidenceSnapshot(ctx context.Context) (*EvidenceSnapshot, error) {
	snap := &EvidenceSnapshot{
		SchemaVersion:  EvidenceSchemaVersion,
		CollectedAt:    time.Now(),
		TruthAuthority: "kernel",
	}

	// v1.89: Call validator directly — sole kernel-query authority.
	valResult, err := validator.ValidateKernel(ctx)
	if err != nil || valResult == nil {
		// Validator failed — entire kernel plane is unknown.
		// nil signals "unknown/unavailable" to correlation and renderer.
		snap.Kernel.Counters = nil
		snap.Kernel.Sets = nil
		snap.Kernel.Chains = nil
		snap.Validator = &ValidatorSnapshot{Status: "unavailable", Unknown: true}
	} else {
		// Extract kernel facts from validator's parsed data.
		snap.Kernel.Counters = extractCountersFromDoc(valResult.Doc)
		snap.Kernel.Sets = extractSetsFromCounts(valResult.Doc, valResult.SetElementCounts)
		snap.Kernel.Chains = extractChainsFromDoc(valResult.Doc)

		// Build validator snapshot from health result.
		snap.Validator = buildValidatorSnapshot(valResult)
	}

	// External evidence plane (journal + data freshness) — independent sources.
	snap.External = CollectJournalEvidence(ctx)
	snap.Freshness = CollectDataFreshness()

	// Correlation plane
	snap.Correlation = CorrelateEvidence(snap.Kernel.Counters, snap.Kernel.Sets, snap.Validator, snap.External)

	return snap, nil
}

// =============================================================================
// v1.89: Extraction functions — read from validator, never query kernel.
// =============================================================================

// extractCountersFromDoc reads named counters from the validator's parsed
// RulesetDocument. Returns nil if the document is nil (collection failed).
// Returns an empty map if no counters exist (valid state, not failure).
func extractCountersFromDoc(doc *validator.RulesetDocument) map[string]CounterValue {
	if doc == nil {
		return nil
	}
	counters := make(map[string]CounterValue)
	for _, family := range []string{"ip", "ip6"} {
		allCounters := doc.GetAllCounters(family, "nftban")
		for name, c := range allCounters {
			key := family + ":" + name
			counters[key] = CounterValue{Packets: c.Packets, Bytes: c.Bytes}
		}
	}
	return counters
}

// extractSetsFromCounts converts validator's set element counts to evidence
// SetInfo structs. Uses both the RulesetDocument (for set existence from the
// schema) and SetElementCounts (for element counts from per-set queries).
//
// Three-state semantics preserved:
//   doc.SetExists=true + count available → Exists=true, Count=N
//   doc.SetExists=false → Exists=false (confirmed absent)
//   doc=nil → Unknown (validator failed)
func extractSetsFromCounts(doc *validator.RulesetDocument, counts map[string]int) map[string]SetInfo {
	if doc == nil || counts == nil {
		return nil
	}
	sets := make(map[string]SetInfo)
	for family, setNames := range Phase1Sets {
		for _, name := range setNames {
			key := family + ":" + name
			if doc.SetExists(family, "nftban", name) {
				count := counts[key] // 0 if not queried (valid: empty set)
				sets[key] = SetInfo{Exists: true, Count: count}
			} else {
				sets[key] = SetInfo{Exists: false}
			}
		}
	}
	return sets
}

// extractChainsFromDoc reads chain presence from the validator's parsed
// RulesetDocument. Checks Phase1Chains in both ip and ip6 families.
func extractChainsFromDoc(doc *validator.RulesetDocument) map[string]ChainInfo {
	if doc == nil {
		return nil
	}
	chains := make(map[string]ChainInfo)
	for _, family := range []string{"ip", "ip6"} {
		for _, chain := range Phase1Chains {
			key := family + ":" + chain
			chains[key] = ChainInfo{
				Exists: doc.ChainExists(family, "nftban", chain),
			}
		}
	}
	return chains
}

// buildValidatorSnapshot converts a ValidationResult into the evidence
// ValidatorSnapshot model. This replaces the external binary call + JSON parse.
func buildValidatorSnapshot(r *validator.ValidationResult) *ValidatorSnapshot {
	snap := &ValidatorSnapshot{
		Status:  string(r.Status),
		Modules: make(map[string]string),
	}

	if r.Modules.DDoS != nil {
		snap.Modules["ddos"] = string(r.Modules.DDoS.Effective)
	}
	if r.Modules.BotGuard != nil {
		snap.Modules["botguard"] = string(r.Modules.BotGuard.Effective)
	}
	if r.Modules.Portscan != nil {
		snap.Modules["portscan"] = string(r.Modules.Portscan.Effective)
	}
	if r.Modules.LoginMon != nil {
		snap.Modules["loginmon"] = string(r.Modules.LoginMon.Effective)
	}
	if r.Modules.Blacklist != nil {
		snap.Modules["blacklist_manual"] = r.Modules.Blacklist.Manual.State
		snap.Modules["blacklist_feeds"] = r.Modules.Blacklist.Feeds.State
		snap.Modules["blacklist_geoban"] = r.Modules.Blacklist.Geoban.State
	}

	for _, f := range r.Findings {
		snap.Findings = append(snap.Findings, f.Code)
	}

	return snap
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

		// M88-1: Total processed packets (all counters summed)
		var totalPackets int64
		for _, cv := range snap.Kernel.Counters {
			totalPackets += cv.Packets
		}
		fmt.Fprintf(w, "\n")
		fmt.Fprintf(w, "  Total counted packets: %d\n", totalPackets)
		fmt.Fprintf(w, "  (sum of all nftables counters: accepts, drops, and flow markers)\n")

		// M88-6: Anchor flow (7 anchors)
		anchorKeys := []string{
			"ip:anchor_hygiene", "ip:anchor_trusted", "ip:anchor_ban",
			"ip:anchor_established", "ip:anchor_detect", "ip:anchor_service", "ip:anchor_final",
		}
		anyAnchor := false
		for _, key := range anchorKeys {
			if cv, ok := snap.Kernel.Counters[key]; ok {
				if !anyAnchor {
					fmt.Fprintf(w, "\n")
					fmt.Fprintf(w, "Anchor Flow (pipeline stage transitions, not enforcement)\n")
					fmt.Fprintf(w, "────────────────────────────────────────\n")
					anyAnchor = true
				}
				name := key[3:] // strip "ip:" prefix
				fmt.Fprintf(w, "  %-38s %d packets\n", name, cv.Packets)
			}
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

	// v1.88: Journal evidence (LoginMon activity)
	if snap.External != nil && !snap.External.Unknown {
		fmt.Fprintf(w, "Journal Evidence (15m window)\n")
		fmt.Fprintf(w, "────────────────────────────────────────\n")
		fmt.Fprintf(w, "  LoginMon active:   %v\n", snap.External.LoginMonActive)
		if snap.External.LoginMonBans > 0 {
			fmt.Fprintf(w, "  LoginMon bans:     %d\n", snap.External.LoginMonBans)
		}
		if snap.External.LoginMonEvents > 0 {
			fmt.Fprintf(w, "  LoginMon events:   %d\n", snap.External.LoginMonEvents)
		}
		fmt.Fprintf(w, "\n")
	} else if snap.External != nil && snap.External.Unknown {
		fmt.Fprintf(w, "Journal Evidence\n")
		fmt.Fprintf(w, "────────────────────────────────────────\n")
		fmt.Fprintf(w, "  (journal evidence unavailable)\n")
		fmt.Fprintf(w, "\n")
	}

	// M88-3/4: Data pipeline freshness
	if snap.Freshness != nil {
		fmt.Fprintf(w, "Data Pipeline Freshness\n")
		fmt.Fprintf(w, "────────────────────────────────────────\n")
		if snap.Freshness.FeedAge != "" {
			fresh := "stale"
			if snap.Freshness.FeedFresh {
				fresh = "fresh"
			}
			fmt.Fprintf(w, "  Feed data:         %s (%s old)\n", fresh, snap.Freshness.FeedAge)
		} else {
			fmt.Fprintf(w, "  Feed data:         no data files\n")
		}
		if snap.Freshness.GeoIPAge != "" {
			fresh := "stale"
			if snap.Freshness.GeoIPFresh {
				fresh = "fresh"
			}
			fmt.Fprintf(w, "  GeoIP database:    %s (%s old)\n", fresh, snap.Freshness.GeoIPAge)
		} else {
			fmt.Fprintf(w, "  GeoIP database:    not found\n")
		}
		fmt.Fprintf(w, "\n")
	}

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
	fmt.Fprintf(w, "  - LoginMon uses shared blacklist sets; journal evidence supplements.\n")
	fmt.Fprintf(w, "  - Anchor counters track pipeline flow stages, not enforcement.\n")
	fmt.Fprintf(w, "  - Correlation is diagnostic only — does not determine protection state.\n")
}
