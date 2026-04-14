// =============================================================================
// NFTBan v1.78 - Kernel Truth Validator Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator-types"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="Type definitions for kernel state validation"
// meta:inventory.files="internal/validator/types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import "time"

// Status represents the overall protection state.
type Status string

const (
	// StatusProtected means all validation checks passed and at least one module active.
	StatusProtected Status = "protected"
	// StatusIdle means all axes pass but no relevant traffic observed. Exit 0.
	StatusIdle Status = "idle"
	// StatusDegraded means partial protection - some checks failed.
	StatusDegraded Status = "degraded"
	// StatusDown means no viable nftban protection detected.
	StatusDown Status = "down"
)

// Severity for findings.
type Severity string

const (
	SeverityInfo     Severity = "info"
	SeverityWarn     Severity = "warn"
	SeverityError    Severity = "error"
	SeverityCritical Severity = "critical"
)

// ValidationResult is the complete output of kernel validation.
type ValidationResult struct {
	SchemaVersion string           `json:"schema_version"`
	Status        Status           `json:"status"`
	Timestamp     time.Time        `json:"timestamp"`
	Families      []FamilyResult   `json:"families"`
	Findings      []Finding        `json:"findings"`
	Summary       SummaryCounts    `json:"summary"`
	ModuleTruth   ModuleStatus     `json:"module_truth"`
	ChainCount    ChainCounts      `json:"chain_counts"`
	ServiceState  ServiceState     `json:"service_state"`
	Modules              ModuleHealthMap  `json:"modules"`                // M81-4
	ConsistencyOverall   string           `json:"consistency_overall"`    // v1.82: "ok" | "mismatch"
}

// SchemaVersionCurrent is the frozen schema version per M81-6.
const SchemaVersionCurrent = "1.81.0"

// =============================================================================
// M81-4: Per-module health state types
// =============================================================================
// Each module is evaluated on: config, structural, runtime, effective axes.
// State values use vocabulary-approved terms from NFTBAN_VOCABULARY_REFERENCE.

// ConfigState represents operator intent from config files.
type ConfigState string

const (
	ConfigEnabled  ConfigState = "enabled"
	ConfigDisabled ConfigState = "disabled"
)

// StructuralState represents kernel object presence.
type StructuralState string

const (
	StructuralPresent StructuralState = "present"
	StructuralMissing StructuralState = "missing"
)

// EffectiveState represents the module's activity level based on evidence.
type EffectiveState string

const (
	EffectiveEnforcing EffectiveState = "enforcing"
	EffectiveObserving EffectiveState = "observing"
	EffectiveIdle      EffectiveState = "idle"
	EffectivePrimed    EffectiveState = "primed"
)

// ModuleHealth holds the 4-axis health evaluation for one module.
type ModuleHealth struct {
	Config     ConfigState     `json:"config"`
	Structural StructuralState `json:"structural,omitempty"`
	Runtime    RuntimeState    `json:"runtime,omitempty"`
	Effective  EffectiveState  `json:"effective,omitempty"`
}

// BlacklistHealth holds the split blacklist state per M81-3 contract.
type BlacklistHealth struct {
	Manual BlacklistSubHealth `json:"manual"`
	Feeds  BlacklistSubHealth `json:"feeds"`
	Geoban BlacklistSubHealth `json:"geoban"`
}

// BlacklistSubHealth represents a blacklist sub-source state.
type BlacklistSubHealth struct {
	State   string `json:"state"`             // enforcing|primed|idle|loaded|stale|disabled
	Entries int    `json:"entries,omitempty"`  // element count (manual/feeds)
	Drops   int64  `json:"drops,omitempty"`   // counter value (manual only — attributable)
}

// ModuleHealthMap holds all per-module health evaluations.
type ModuleHealthMap struct {
	BotGuard  *ModuleHealth    `json:"botguard,omitempty"`
	DDoS      *ModuleHealth    `json:"ddos,omitempty"`
	Portscan  *ModuleHealth    `json:"portscan,omitempty"`
	LoginMon  *ModuleHealth    `json:"loginmon,omitempty"`
	Blacklist *BlacklistHealth `json:"blacklist,omitempty"`
}

// RuntimeState represents a three-state service status.
// Aligns with the v1.82 health model direction (RUNNING / STOPPED / ERROR).
type RuntimeState string

const (
	RuntimeRunning RuntimeState = "RUNNING"
	RuntimeStopped RuntimeState = "STOPPED"
	RuntimeError   RuntimeState = "ERROR" // systemctl query itself failed
)

// ServiceState holds the live status of required system services.
// B80-4: the validator MUST check these before declaring PROTECTED.
// A system with correct kernel structure but a dead daemon is not protected.
type ServiceState struct {
	Nftband      RuntimeState `json:"nftband"`
	NftbandDetail string      `json:"nftband_detail,omitempty"`
}

// FamilyResult holds validation results for a single address family (ip/ip6).
type FamilyResult struct {
	Family       string       `json:"family"` // "ip" or "ip6"
	Status       Status       `json:"status"`
	TablePresent bool         `json:"table_present"`
	ChainCount   int          `json:"chain_count"`
	SetCount     int          `json:"set_count"`
	BaseChains   ChainCheck   `json:"base_chains"`
	HelperChains ChainCheck   `json:"helper_chains"`
	Anchors      AnchorCheck  `json:"anchors"`
	Sets         SetCheck     `json:"sets"`
}

// ChainCheck holds chain validation results.
type ChainCheck struct {
	Required []string `json:"required"`
	Found    []string `json:"found"`
	Missing  []string `json:"missing"`
	AllFound bool     `json:"all_found"`
}

// AnchorCheck holds anchor validation results.
type AnchorCheck struct {
	RequiredCount int      `json:"required_count"`
	FoundCount    int      `json:"found_count"`
	Ordered       bool     `json:"ordered"`
	AnchorsFound  []string `json:"anchors_found"`
	Missing       []string `json:"missing"`
	OrderExpected []string `json:"order_expected"`
	OrderActual   []string `json:"order_actual"`
	FinalPresent  bool     `json:"final_present"` // FINAL GUARD invariant
}

// SetCheck holds set validation results.
type SetCheck struct {
	Required []string `json:"required"`
	Found    []string `json:"found"`
	Missing  []string `json:"missing"`
	AllFound bool     `json:"all_found"`
}

// ModuleStatus holds runtime truth about protection modules.
type ModuleStatus struct {
	DDoS             ModuleInfo `json:"ddos"`
	Portscan         ModuleInfo `json:"portscan"`
	Blacklist        ModuleInfo `json:"blacklist"`
	Whitelist        ModuleInfo `json:"whitelist"`
	ServiceAdmission ModuleInfo `json:"service_admission"`
}

// ModuleInfo holds information about a single module.
type ModuleInfo struct {
	Enabled       bool   `json:"enabled"`
	KernelPresent bool   `json:"kernel_present"`
	Details       string `json:"details,omitempty"`
}

// ChainCounts for relative comparison (rebuild safety).
type ChainCounts struct {
	IPv4Total   int `json:"ipv4_total"`
	IPv4Base    int `json:"ipv4_base"`
	IPv4Helper  int `json:"ipv4_helper"`
	IPv6Total   int `json:"ipv6_total"`
	IPv6Base    int `json:"ipv6_base"`
	IPv6Helper  int `json:"ipv6_helper"`
	TotalChains int `json:"total_chains"`
}

// SummaryCounts provides quick stats.
type SummaryCounts struct {
	TotalFindings    int `json:"total_findings"`
	CriticalFindings int `json:"critical_findings"`
	ErrorFindings    int `json:"error_findings"`
	WarnFindings     int `json:"warn_findings"`
	CheckedFamilies  int `json:"checked_families"`
	ProtectedFams    int `json:"protected_families"`
	DegradedFams     int `json:"degraded_families"`
}

// Finding represents a single validation finding.
type Finding struct {
	Code        string   `json:"code"`
	Severity    Severity `json:"severity"`
	Component   string   `json:"component"`
	Family      string   `json:"family,omitempty"`
	Message     string   `json:"message"`
	Remediation string   `json:"remediation,omitempty"`
}

// Finding codes (stable for automation).
const (
	// Table findings
	CodeTableMissing     = "VAL-TABLE-001"
	CodeTableBothMissing = "VAL-TABLE-002"

	// Chain findings
	CodeChainMissing       = "VAL-CHAIN-001"
	CodeHelperChainMissing = "VAL-CHAIN-002"
	CodeChainCountDrop     = "VAL-CHAIN-003"
	CodeChainEmpty         = "VAL-CHAIN-004" // B80-3: chain exists but has no rules

	// Anchor findings
	CodeAnchorMissing  = "VAL-ANCHOR-001"
	CodeAnchorOrder    = "VAL-ANCHOR-002"
	CodeAnchorFinal    = "VAL-ANCHOR-003" // FINAL GUARD
	CodeAnchorTruncate = "VAL-ANCHOR-004"

	// Set findings
	CodeSetMissing = "VAL-SET-001"

	// Module findings
	CodeModuleDegraded = "VAL-MODULE-001"

	// Service findings (B80-4)
	CodeServiceDown = "VAL-SERVICE-001" // required service not active

	// Module-specific findings (M81-4)
	CodeGeobanDBMissing = "VAL-GEOBAN-001" // geoip database missing/empty

	// Consistency findings (v1.82)
	CodeConsistencyMismatch = "VAL-CONS-001" // config/kernel disagreement

	// System findings
	CodeNftFailed    = "VAL-SYSTEM-001"
	CodeNftNoOutput  = "VAL-SYSTEM-002"
	CodeParseError   = "VAL-SYSTEM-003"
)

// Required anchors in strict order.
// AUTHORITY NOTE (B80-5): Anchors are a validator-defined invariant, NOT
// derived from the shell schema. They represent the required rule-comment
// sequence in the input chain. The canonical authority for chains/sets is
// nft_schema.sh via schema_generated.go. The canonical authority for anchor
// ordering is this list, maintained manually in this file.
var RequiredAnchors = []string{
	"ANCHOR_HYGIENE",
	"ANCHOR_TRUSTED",
	"ANCHOR_BAN",
	"ANCHOR_ESTABLISHED",
	"ANCHOR_DETECT",
	"ANCHOR_SERVICE",
	"ANCHOR_FINAL",
}

// Required base chains per family.
// B80-5/6: sourced from schema_generated.go (canonical: cli/lib/nftban/lib/nft_schema.sh).
var RequiredBaseChains = GeneratedRequiredBaseChains

// Required helper chains per family. Currently EMPTY — all helper chains are
// module-scoped (only exist when their module is enabled). Base PROTECTED
// does not require any helper chains. Module-level chain validation is
// handled by deriveModuleTruth() which checks presence per-module.
var RequiredHelperChains = GeneratedRequiredHelperChains

// AllHelperChains lists all known helper chains for module-truth derivation
// and informational reporting. Not used for base structural validation.
var AllHelperChains = GeneratedAllHelperChains

// Required sets for IPv4.
// B80-5/6: sourced from schema_generated.go (core required sets only).
var RequiredSetsIPv4 = GeneratedRequiredSetsIPv4

// Required sets for IPv6.
// B80-5/6: sourced from schema_generated.go (core required sets only).
var RequiredSetsIPv6 = GeneratedRequiredSetsIPv6
