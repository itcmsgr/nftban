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
	// StatusProtected means all validation checks passed.
	StatusProtected Status = "protected"
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
	Status      Status           `json:"status"`
	Timestamp   time.Time        `json:"timestamp"`
	Families    []FamilyResult   `json:"families"`
	Findings    []Finding        `json:"findings"`
	Summary     SummaryCounts    `json:"summary"`
	ModuleTruth ModuleStatus     `json:"module_truth"`
	ChainCount  ChainCounts      `json:"chain_counts"`
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

	// Anchor findings
	CodeAnchorMissing  = "VAL-ANCHOR-001"
	CodeAnchorOrder    = "VAL-ANCHOR-002"
	CodeAnchorFinal    = "VAL-ANCHOR-003" // FINAL GUARD
	CodeAnchorTruncate = "VAL-ANCHOR-004"

	// Set findings
	CodeSetMissing = "VAL-SET-001"

	// Module findings
	CodeModuleDegraded = "VAL-MODULE-001"

	// System findings
	CodeNftFailed    = "VAL-SYSTEM-001"
	CodeNftNoOutput  = "VAL-SYSTEM-002"
	CodeParseError   = "VAL-SYSTEM-003"
)

// Required anchors in strict order.
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
var RequiredBaseChains = []string{
	"input",
	"forward",
	"output",
}

// Required helper chains per family.
var RequiredHelperChains = []string{
	"ddos_sanity",
	"ddos_penalty",
	"ddos_prefix",
	"ddos_protection",
	"portscan_detection",
}

// Required sets for IPv4.
var RequiredSetsIPv4 = []string{
	"whitelist_ipv4",
	"blacklist_ipv4",
	"blacklist_manual_ipv4",
	"tcp_ports_in",
	"udp_ports_in",
}

// Required sets for IPv6.
var RequiredSetsIPv6 = []string{
	"whitelist_ipv6",
	"blacklist_ipv6",
	"blacklist_manual_ipv6",
	"tcp_ports_in",
	"udp_ports_in",
}
