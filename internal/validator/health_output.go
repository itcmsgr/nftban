// =============================================================================
// NFTBan v1.81 - Health JSON Output (M81-6 Schema Contract)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="health_output"
// meta:type="lib"
// meta:version="1.81.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="JSON output schema types and mapper per JSON_SCHEMA_SPEC_v1.81.md"
// meta:inventory.files="internal/validator/health_output.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// This file defines the JSON OUTPUT contract. It is a PROJECTION layer only.
// It MUST NOT contain derivation logic — that belongs in module_health.go.
// It MUST NOT contain evaluation logic — that belongs in validator.go.
//
// All field values are vocabulary-approved terms from
// NFTBAN_VOCABULARY_REFERENCE_v1.81.md.
// Schema frozen per JSON_SCHEMA_SPEC_v1.81.md.
// =============================================================================
package validator

// HealthOutput is the top-level JSON output structure for nftban-validate --json.
// This is the canonical M81-6 schema. Fields MUST NOT be added without a
// schema version bump. See JSON_SCHEMA_SPEC_v1.81.md Section 8.
type HealthOutput struct {
	SchemaVersion string              `json:"schema_version"`
	Status        string              `json:"status"`
	Timestamp     string              `json:"timestamp"`
	ServiceState  ServiceStateJSON    `json:"service_state"`
	Modules       ModulesJSON         `json:"modules"`
	Consistency   ConsistencyJSON     `json:"consistency"`
	Findings      []FindingJSON       `json:"findings"`
	ChainCounts   ChainCounts         `json:"chain_counts"`
	Summary       SummaryCounts       `json:"summary"`
}

// ServiceStateJSON is the JSON representation of daemon state.
type ServiceStateJSON struct {
	Nftband       string `json:"nftband"`                  // RUNNING|STOPPED|ERROR
	NftbandDetail string `json:"nftband_detail,omitempty"` // raw systemctl output
}

// ModulesJSON holds all per-module health in JSON output form.
// Disabled modules emit config only (no other fields).
// No nulls. Omitted fields = not applicable.
type ModulesJSON struct {
	BotGuard  *ModuleJSON    `json:"botguard,omitempty"`
	DDoS      *ModuleJSON    `json:"ddos,omitempty"`
	Portscan  *ModuleJSON    `json:"portscan,omitempty"`
	LoginMon  *ModuleJSON    `json:"loginmon,omitempty"`
	Blacklist *BlacklistJSON `json:"blacklist,omitempty"`
}

// ModuleJSON is the standard 4-axis module output.
// Fields are omitted when not applicable (e.g. runtime for kernel-only modules).
type ModuleJSON struct {
	Config     string `json:"config"`                // enabled|disabled (always present)
	Structural string `json:"structural,omitempty"`  // present|missing (omitted if disabled)
	Runtime    string `json:"runtime,omitempty"`     // running|stopped (omitted if not daemon-dependent)
	Effective  string `json:"effective,omitempty"`   // enforcing|observing|idle (omitted if disabled)
}

// BlacklistJSON is the composite blacklist module output.
// Does NOT follow the 4-axis model — blacklist is source-split.
type BlacklistJSON struct {
	Manual BlacklistSubJSON `json:"manual"`
	Feeds  BlacklistSubJSON `json:"feeds"`
	Geoban BlacklistSubJSON `json:"geoban"`
}

// BlacklistSubJSON represents one blacklist source.
type BlacklistSubJSON struct {
	State   string `json:"state"`            // enforcing|primed|idle|loaded|stale|degraded|disabled
	Entries int    `json:"entries,omitempty"` // element count (omitted if 0 or not applicable)
	Drops   int64  `json:"drops,omitempty"`  // counter value (omitted if 0 or not attributable)
}

// ConsistencyJSON holds cross-source agreement status.
// Stub for v1.81.0 — expanded in v1.82.
type ConsistencyJSON struct {
	KernelVsValidator string `json:"kernel_vs_validator"` // ok|mismatch
}

// FindingJSON is a single validation finding in the output.
type FindingJSON struct {
	Code        string `json:"code"`
	Severity    string `json:"severity"`              // info|warn|error|critical
	Component   string `json:"component"`
	Family      string `json:"family,omitempty"`
	Message     string `json:"message"`
	Remediation string `json:"remediation,omitempty"`
}
