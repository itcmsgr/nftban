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
	SchemaVersion      string          `json:"schema_version"`
	Status             Status          `json:"status"`
	Timestamp          time.Time       `json:"timestamp"`
	Families           []FamilyResult  `json:"families"`
	Findings           []Finding       `json:"findings"`
	Summary            SummaryCounts   `json:"summary"`
	ChainCount         ChainCounts     `json:"chain_counts"`
	ServiceState       ServiceState    `json:"service_state"`
	Modules            ModuleHealthMap `json:"modules"`             // M81-4
	ConsistencyOverall string          `json:"consistency_overall"` // v1.82: "ok" | "mismatch"

	// v1.89 INV-M-001/002: Expose kernel state for evidence layer.
	// These fields are internal — not serialized to the frozen JSON schema.
	Doc              *RulesetDocument `json:"-"` // parsed kernel ruleset (counters, chains, sets)
	SetElementCounts map[string]int   `json:"-"` // "family:set" → element count
}

// SchemaVersionCurrent is the output/IPC schema version per M81-6.
// v1.83: bumped for timer_count addition to service_state.
// v1.190.0 SCHEMA-UNFREEZE: deliberate bump 1.83.0 → 1.84.0 — adds the counters
// CONTRACT (additive, omitempty/absent until populated in v1.191.0) + the
// counters_phase marker. Coordinated with the freeze-guard tests in
// internal/{blacklist,whitelist,installer/render,validator}. Additive-only:
// existing fields/types unchanged so old consumers keep parsing.
const SchemaVersionCurrent = "1.84.0"

// CountersPhaseContract / CountersPhasePopulated are the counters_phase values.
// v1.190.0 emits "contract" (schema/fields defined, NOT populated → consumers must
// NOT read absent/zero as real). v1.191.0 will emit "populated" once live counters move.
const (
	CountersPhaseContract  = "contract"
	CountersPhasePopulated = "populated"
)

// =============================================================================
// =============================================================================
// v1.86: Module Classification (B86-2 clarity)
// =============================================================================
// Every config-present module MUST be classified. No unclassified modules allowed.
//
// Classification taxonomy:
//   CORE_MODULE  — user-visible protection module with its own evaluator + JSON + tests
//   CORE_INFRA   — required internal support; no dedicated evaluator, served by parent
//   ADVISORY     — non-blocking, no kernel enforcement, no validator claim
//   MONITOR      — runtime observation only, no direct protection claim
//   EXTERNAL     — third-party integration, outside validator scope

// ModuleClass defines a module's role in the system.
type ModuleClass string

const (
	ModuleCoreModule ModuleClass = "core_module" // Protection module: evaluator + JSON + tests required
	ModuleCoreInfra  ModuleClass = "core_infra"  // Internal support: served by parent evaluator
	ModuleAdvisory   ModuleClass = "advisory"    // Non-blocking, no kernel enforcement
	ModuleMonitor    ModuleClass = "monitor"     // Observes but does not enforce
	ModuleExternal   ModuleClass = "external"    // Third-party integration, deferred
)

// ModuleClassification maps every config-present module to its class.
// This is the completeness contract: if a module has a config directory,
// it MUST appear here. CI gate G8-2 enforces this.
//
// CORE_MODULE entries MUST have: evaluator + ModuleHealthMap field + JSON + tests.
// CORE_INFRA entries are served by a parent module's evaluator.
// ADVISORY/MONITOR/EXTERNAL entries MUST NOT appear in evaluator or JSON.
var ModuleClassification = map[string]ModuleClass{
	// CORE_MODULE — protection modules with dedicated evaluators
	"ddos":     ModuleCoreModule, // evaluateDDoS()
	"botguard": ModuleCoreModule, // evaluateBotGuard()
	"portscan": ModuleCoreModule, // evaluatePortscan()
	"loginmon": ModuleCoreModule, // evaluateLoginMon() (config dir: login, login_alert)
	"geoban":   ModuleCoreModule, // sub-state of evaluateBlacklist()

	// CORE_INFRA — internal support, served by parent evaluators
	"botscan": ModuleCoreInfra, // BotGuard sub-function (L7 batch scanning)
	"geoip":   ModuleCoreInfra, // GeoIP database management (serves geoban)
	"panels":  ModuleCoreInfra, // Panel detection (installer infrastructure)

	// ADVISORY — non-blocking, no kernel enforcement
	"tunnel": ModuleAdvisory, // DNS tunnel suspicion (scoring only)

	// MONITOR — observes, does not enforce
	"rbl": ModuleMonitor, // RBL/DNSBL monitoring

	// EXTERNAL — third-party integration, deferred from validator scope
	"suricata": ModuleExternal,
}

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

// InputState represents detection-source input readability (v1.183 HEALTH-NO-INPUT-AXIS
// increment 2). It makes an enabled-but-starved module visible in `nftban health` instead
// of reading healthy. Derived from the daemon's "[LOGINMON] <src>: state=..." journal
// lines (the daemon is the authority on its own watchers). Omitted unless determinable.
type InputState string

const (
	InputOK         InputState = "ok"           // a source is present + producing input
	InputWarnNoLogs InputState = "warn_no_logs" // stack present but no logs / no recent lines
	InputNoLogs     InputState = "no_logs"      // no source/daemon for an enabled module
	InputUnknown    InputState = "unknown"      // no input-state evidence available
)

// ModuleHealth holds the per-module health evaluation. v1.183 adds the Input axis
// (input-readability) as an INTERNAL field (json:"-") — it drives a findings-array signal
// (CodeLoginMonNoInput) which is the schema-safe way to surface enabled-but-starved in
// `nftban health`. The frozen M81-6 health-output schema (ModuleJSON) is NOT extended here;
// promoting Input to a first-class JSON axis is deferred to the SCHEMA-UNFREEZE major.
type ModuleHealth struct {
	Config     ConfigState     `json:"config"`
	Structural StructuralState `json:"structural,omitempty"`
	Runtime    RuntimeState    `json:"runtime,omitempty"`
	Effective  EffectiveState  `json:"effective,omitempty"`
	Input      InputState      `json:"-"` // internal (v1.183); surfaced via CodeLoginMonNoInput finding, not the frozen schema
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
	Entries int    `json:"entries,omitempty"` // element count (manual/feeds)
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
	Nftband       RuntimeState `json:"nftband"`
	NftbandDetail string       `json:"nftband_detail,omitempty"`
	TimerCount    int          `json:"timer_count"` // v1.83: active nftban-* timer count
}

// FamilyResult holds validation results for a single address family (ip/ip6).
type FamilyResult struct {
	Family       string      `json:"family"` // "ip" or "ip6"
	Status       Status      `json:"status"`
	TablePresent bool        `json:"table_present"`
	ChainCount   int         `json:"chain_count"`
	SetCount     int         `json:"set_count"`
	BaseChains   ChainCheck  `json:"base_chains"`
	HelperChains ChainCheck  `json:"helper_chains"`
	Anchors      AnchorCheck `json:"anchors"`
	Sets         SetCheck    `json:"sets"`
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

// v1.86 B86-1: ModuleStatus and ModuleInfo deleted.
// ModuleHealthMap (M81-4) is the only canonical module inventory.

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
	CodeTimerNone   = "VAL-TIMER-001"   // v1.83: no nftban timers active
	CodeTimerError  = "VAL-TIMER-002"   // v1.83: timer query failed

	// Module-specific findings (M81-4)
	CodeGeobanDBMissing    = "VAL-GEOBAN-001"   // geoip database missing/empty
	CodeBotGuardNoEvidence = "VAL-BOTGUARD-001" // v1.84: no recent BotGuard runtime evidence
	CodeLoginMonNoEvidence = "VAL-LOGINMON-001" // v1.84: no recent LoginMon runtime evidence
	CodeLoginMonNoInput    = "VAL-LOGINMON-002" // v1.183: enabled but a detection source reports no input

	// Consistency findings (v1.82)
	CodeConsistencyMismatch = "VAL-CONS-001" // config/kernel disagreement

	// System findings
	CodeNftFailed   = "VAL-SYSTEM-001"
	CodeNftNoOutput = "VAL-SYSTEM-002"
	CodeParseError  = "VAL-SYSTEM-003"
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
// handled by per-module evaluators in module_health.go.
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
