// =============================================================================
// NFTBan v1.78 - Kernel Truth Validator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="Validates live nftables kernel state against NFTBan requirements"
// meta:inventory.files="internal/validator/validator.go"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// CRITICAL: This validator is ZERO-SIDE-EFFECT.
// It MUST NEVER write files, modify nft, or call mutating shell scripts.
// =============================================================================
package validator

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// ServiceChecker abstracts service-state queries so unit tests can mock
// systemd without requiring a real init system. The default implementation
// calls `systemctl is-active <unit>`.
type ServiceChecker interface {
	// CheckUnit returns (RuntimeState, detail string).
	// RuntimeState: RUNNING / STOPPED / ERROR.
	// detail: the raw systemctl output (e.g. "active", "inactive", "failed").
	CheckUnit(unit string) (RuntimeState, string)
}

// SystemdChecker is the default production ServiceChecker.
type SystemdChecker struct{}

// CheckUnit queries systemd for the unit's active state.
// This is a read-only query — zero side effects.
func (SystemdChecker) CheckUnit(unit string) (RuntimeState, string) {
	out, err := exec.Command("systemctl", "is-active", unit).Output()
	detail := strings.TrimSpace(string(out))
	if err != nil {
		if detail == "" {
			detail = "unknown"
		}
		// Distinguish known systemd states from exec errors.
		// "activating"/"deactivating"/"reloading" are transition states —
		// the daemon is not yet running, so they map to STOPPED (not ERROR).
		// This prevents misleading ERROR findings during rebuild/startup.
		if detail == "inactive" || detail == "failed" || detail == "dead" ||
			detail == "activating" || detail == "deactivating" || detail == "reloading" {
			return RuntimeStopped, detail
		}
		return RuntimeError, detail
	}
	if detail == "active" {
		return RuntimeRunning, detail
	}
	return RuntimeStopped, detail
}

// defaultServiceChecker is set at package level and can be overridden
// by tests via SetServiceChecker.
var defaultServiceChecker ServiceChecker = SystemdChecker{}

// SetServiceChecker replaces the service checker (for testing only).
func SetServiceChecker(sc ServiceChecker) {
	defaultServiceChecker = sc
}

// ValidateKernel performs complete kernel state validation.
// This is the main entrypoint for the validator.
//
// CRITICAL: This function is PURE - it only reads, never modifies.
func ValidateKernel(ctx context.Context) (*ValidationResult, error) {
	result := &ValidationResult{
		SchemaVersion: SchemaVersionCurrent,
		Timestamp:     time.Now(),
		Findings:      make([]Finding, 0),
		Families:      make([]FamilyResult, 0, 2),
	}

	// Load ruleset from kernel
	ruleset, err := LoadRulesetJSON(ctx)
	if err != nil {
		result.Status = StatusDown
		result.Findings = append(result.Findings, Finding{
			Code:        CodeNftFailed,
			Severity:    SeverityCritical,
			Component:   "kernel",
			Message:     "Failed to load nftables ruleset: " + err.Error(),
			Remediation: "Check nft command availability and permissions",
		})
		result.Summary = computeSummary(result)
		return result, nil // Return result, not error - DOWN is a valid state
	}

	if ruleset == nil || len(ruleset.Nftables) == 0 {
		result.Status = StatusDown
		result.Findings = append(result.Findings, Finding{
			Code:        CodeNftNoOutput,
			Severity:    SeverityCritical,
			Component:   "kernel",
			Message:     "nft returned empty ruleset",
			Remediation: "Run: nftban firewall rebuild",
		})
		result.Summary = computeSummary(result)
		return result, nil
	}

	// Parse into structured document
	doc := ParseRuleset(ruleset)

	// Validate each family
	ipv4Result := validateFamily(doc, "ip", result)
	ipv6Result := validateFamily(doc, "ip6", result)

	result.Families = append(result.Families, ipv4Result, ipv6Result)

	// Check for both tables missing = DOWN
	if !ipv4Result.TablePresent && !ipv6Result.TablePresent {
		result.Status = StatusDown
		result.Findings = append(result.Findings, Finding{
			Code:        CodeTableBothMissing,
			Severity:    SeverityCritical,
			Component:   "kernel",
			Message:     "Neither ip nor ip6 nftban table exists",
			Remediation: "Run: nftban firewall rebuild",
		})
	}

	// Compute chain counts for relative comparison
	result.ChainCount = ChainCounts{
		IPv4Total:  doc.CountChains("ip"),
		IPv6Total:  doc.CountChains("ip6"),
		IPv4Base:   countFoundChains(ipv4Result.BaseChains.Found),
		IPv4Helper: countFoundChains(ipv4Result.HelperChains.Found),
		IPv6Base:   countFoundChains(ipv6Result.BaseChains.Found),
		IPv6Helper: countFoundChains(ipv6Result.HelperChains.Found),
	}
	result.ChainCount.TotalChains = result.ChainCount.IPv4Total + result.ChainCount.IPv6Total

	// Derive module truth from kernel state
	result.ModuleTruth = deriveModuleTruth(doc)

	// B80-4: Check required service state.
	// A system with correct kernel structure but a dead daemon is not truly
	// protected — the daemon manages runtime objects (BotGuard, LoginMon,
	// scoring) that exist only while it runs. Kernel tables alone are not
	// sufficient for full protection.
	//
	// We check nftband only (not nftables.service) because:
	// - if nftables were down, LoadRulesetJSON above would already fail
	//   or return an empty ruleset → StatusDown via the existing checks
	// - nftband being down is a separate, subtler failure: kernel structure
	//   looks correct but runtime detection/scoring is absent
	result.ServiceState = checkServiceState()
	if result.ServiceState.Nftband != RuntimeRunning {
		result.Findings = append(result.Findings, Finding{
			Code:        CodeServiceDown,
			Severity:    SeverityError,
			Component:   "service",
			Message:     "nftband daemon is not running (state: " + string(result.ServiceState.Nftband) + ", detail: " + result.ServiceState.NftbandDetail + ")",
			Remediation: "Run: systemctl start nftband",
		})
	}

	// M81-4: Per-module health evaluation
	result.Modules = evaluateModuleHealth(doc, result.ServiceState)

	// Compute summary
	result.Summary = computeSummary(result)

	// Determine overall status
	result.Status = evaluateOverallStatus(result)

	return result, nil
}

// validateFamily validates a single address family.
func validateFamily(doc *RulesetDocument, family string, result *ValidationResult) FamilyResult {
	fr := FamilyResult{
		Family: family,
		Status: StatusProtected,
	}

	// Check table exists
	fr.TablePresent = doc.TableExists(family, "nftban")
	if !fr.TablePresent {
		fr.Status = StatusDegraded
		result.Findings = append(result.Findings, Finding{
			Code:      CodeTableMissing,
			Severity:  SeverityError,
			Component: "table",
			Family:    family,
			Message:   family + " nftban table not found",
		})
		return fr
	}

	// Count chains and sets
	fr.ChainCount = doc.CountChains(family)
	fr.SetCount = doc.CountSets(family)

	// Validate base chains
	fr.BaseChains = validateChains(doc, family, RequiredBaseChains, result)
	if !fr.BaseChains.AllFound {
		fr.Status = StatusDegraded
	}

	// Validate helper chains
	fr.HelperChains = validateChains(doc, family, RequiredHelperChains, result)
	if !fr.HelperChains.AllFound {
		fr.Status = StatusDegraded
		for _, missing := range fr.HelperChains.Missing {
			result.Findings = append(result.Findings, Finding{
				Code:        CodeHelperChainMissing,
				Severity:    SeverityError,
				Component:   "chain",
				Family:      family,
				Message:     "Helper chain missing: " + missing,
				Remediation: "Run: nftban ddos enable",
			})
		}
	}

	// B80-3 (INV-S-008): Detect empty helper chains among ALL known helpers.
	// Helper chains are module-scoped (not base-required), so a MISSING chain
	// is fine (module disabled). But a chain that EXISTS with zero rules is a
	// no-op jump target — traffic enters, nothing happens, traffic exits.
	// That silently defeats the protection the module was supposed to provide.
	// This MUST report DEGRADED via SeverityError.
	for _, chain := range AllHelperChains {
		if doc.ChainExists(family, "nftban", chain) {
			ruleCount := doc.CountRulesInChain(family, "nftban", chain)
			if ruleCount == 0 {
				fr.Status = StatusDegraded
				result.Findings = append(result.Findings, Finding{
					Code:        CodeChainEmpty,
					Severity:    SeverityError,
					Component:   "chain",
					Family:      family,
					Message:     "Helper chain exists but has no rules: " + chain + " (no-op jump target)",
					Remediation: "Run: nftban ddos enable (or nftban portscan enable)",
				})
			}
		}
	}

	// Validate anchors
	fr.Anchors = validateAnchors(doc, family, result)
	if !fr.Anchors.Ordered || fr.Anchors.FoundCount < fr.Anchors.RequiredCount {
		fr.Status = StatusDegraded
	}

	// FINAL GUARD: Check input chain ends with ANCHOR_FINAL
	if !fr.Anchors.FinalPresent {
		fr.Status = StatusDegraded
		result.Findings = append(result.Findings, Finding{
			Code:        CodeAnchorFinal,
			Severity:    SeverityCritical,
			Component:   "anchor",
			Family:      family,
			Message:     "Input chain does not end with ANCHOR_FINAL - pipeline incomplete",
			Remediation: "Run: nftban firewall rebuild",
		})
	}

	// Validate sets
	var requiredSets []string
	if family == "ip" {
		requiredSets = RequiredSetsIPv4
	} else {
		requiredSets = RequiredSetsIPv6
	}
	fr.Sets = validateSets(doc, family, requiredSets, result)
	if !fr.Sets.AllFound {
		fr.Status = StatusDegraded
	}

	return fr
}

// validateChains checks for required chains.
func validateChains(doc *RulesetDocument, family string, required []string, result *ValidationResult) ChainCheck {
	check := ChainCheck{
		Required: required,
		Found:    make([]string, 0),
		Missing:  make([]string, 0),
	}

	for _, name := range required {
		if doc.ChainExists(family, "nftban", name) {
			check.Found = append(check.Found, name)
		} else {
			check.Missing = append(check.Missing, name)
			result.Findings = append(result.Findings, Finding{
				Code:      CodeChainMissing,
				Severity:  SeverityError,
				Component: "chain",
				Family:    family,
				Message:   "Required chain missing: " + name,
			})
		}
	}

	check.AllFound = len(check.Missing) == 0
	return check
}

// validateAnchors checks anchor presence and order.
func validateAnchors(doc *RulesetDocument, family string, result *ValidationResult) AnchorCheck {
	check := AnchorCheck{
		RequiredCount: len(RequiredAnchors),
		OrderExpected: RequiredAnchors,
		AnchorsFound:  make([]string, 0),
		Missing:       make([]string, 0),
	}

	// Extract anchors from input chain rules
	anchors := doc.ExtractAnchorsFromChain(family, "nftban", "input")
	check.OrderActual = anchors
	check.FoundCount = len(anchors)

	// Build found set for lookup
	foundSet := make(map[string]bool)
	for _, a := range anchors {
		foundSet[a] = true
		check.AnchorsFound = append(check.AnchorsFound, a)
	}

	// Check for missing anchors
	for _, required := range RequiredAnchors {
		if !foundSet[required] {
			check.Missing = append(check.Missing, required)
			result.Findings = append(result.Findings, Finding{
				Code:      CodeAnchorMissing,
				Severity:  SeverityError,
				Component: "anchor",
				Family:    family,
				Message:   "Required anchor missing: " + required,
			})
		}
	}

	// Check order (strict sequence)
	check.Ordered = checkAnchorOrder(anchors, RequiredAnchors)
	if !check.Ordered && len(check.Missing) == 0 {
		result.Findings = append(result.Findings, Finding{
			Code:      CodeAnchorOrder,
			Severity:  SeverityError,
			Component: "anchor",
			Family:    family,
			Message:   "Anchor order incorrect - expected strict sequence",
		})
	}

	// FINAL GUARD: Check if ANCHOR_FINAL is present and is last
	check.FinalPresent = false
	if len(anchors) > 0 && anchors[len(anchors)-1] == "ANCHOR_FINAL" {
		check.FinalPresent = true
	}

	return check
}

// checkAnchorOrder verifies anchors appear in the expected order.
// Extra anchors between expected ones are allowed, but the sequence must be preserved.
func checkAnchorOrder(actual, expected []string) bool {
	if len(actual) == 0 {
		return false
	}

	// Find each expected anchor in order
	actualIdx := 0
	for _, exp := range expected {
		found := false
		for actualIdx < len(actual) {
			if actual[actualIdx] == exp {
				found = true
				actualIdx++
				break
			}
			actualIdx++
		}
		if !found {
			return false
		}
	}
	return true
}

// validateSets checks for required sets.
func validateSets(doc *RulesetDocument, family string, required []string, result *ValidationResult) SetCheck {
	check := SetCheck{
		Required: required,
		Found:    make([]string, 0),
		Missing:  make([]string, 0),
	}

	for _, name := range required {
		if doc.SetExists(family, "nftban", name) {
			check.Found = append(check.Found, name)
		} else {
			check.Missing = append(check.Missing, name)
			result.Findings = append(result.Findings, Finding{
				Code:      CodeSetMissing,
				Severity:  SeverityWarn,
				Component: "set",
				Family:    family,
				Message:   "Required set missing: " + name,
			})
		}
	}

	check.AllFound = len(check.Missing) == 0
	return check
}

// deriveModuleTruth determines module status from kernel presence.
func deriveModuleTruth(doc *RulesetDocument) ModuleStatus {
	ms := ModuleStatus{}

	// DDoS: enabled if all helper chains exist
	ddosChains := []string{"ddos_sanity", "ddos_penalty", "ddos_prefix", "ddos_protection"}
	ddosPresent := true
	for _, chain := range ddosChains {
		if !doc.ChainExists("ip", "nftban", chain) {
			ddosPresent = false
			break
		}
	}
	ms.DDoS = ModuleInfo{
		Enabled:       ddosPresent,
		KernelPresent: ddosPresent,
		Details:       boolToStatus(ddosPresent, "all helper chains present", "helper chains missing"),
	}

	// Portscan: enabled if chain exists
	portscanPresent := doc.ChainExists("ip", "nftban", "portscan_detection")
	ms.Portscan = ModuleInfo{
		Enabled:       portscanPresent,
		KernelPresent: portscanPresent,
		Details:       boolToStatus(portscanPresent, "chain present", "chain missing"),
	}

	// Blacklist: enabled if sets exist
	blacklistPresent := doc.SetExists("ip", "nftban", "blacklist_ipv4") &&
		doc.SetExists("ip", "nftban", "blacklist_manual_ipv4")
	ms.Blacklist = ModuleInfo{
		Enabled:       blacklistPresent,
		KernelPresent: blacklistPresent,
		Details:       boolToStatus(blacklistPresent, "sets present", "sets missing"),
	}

	// Whitelist: enabled if set exists
	whitelistPresent := doc.SetExists("ip", "nftban", "whitelist_ipv4")
	ms.Whitelist = ModuleInfo{
		Enabled:       whitelistPresent,
		KernelPresent: whitelistPresent,
		Details:       boolToStatus(whitelistPresent, "set present", "set missing"),
	}

	// Service admission: enabled if port sets exist
	servicePresent := doc.SetExists("ip", "nftban", "tcp_ports_in") &&
		doc.SetExists("ip", "nftban", "udp_ports_in")
	ms.ServiceAdmission = ModuleInfo{
		Enabled:       servicePresent,
		KernelPresent: servicePresent,
		Details:       boolToStatus(servicePresent, "port sets present", "port sets missing"),
	}

	return ms
}

// checkServiceState queries the runtime state of required services.
// B80-4: nftband must be RUNNING for full protection. STOPPED or ERROR
// both produce findings that evaluateOverallStatus will catch.
func checkServiceState() ServiceState {
	ss := ServiceState{}
	state, detail := defaultServiceChecker.CheckUnit("nftband")
	ss.Nftband = state
	ss.NftbandDetail = detail
	return ss
}

// evaluateOverallStatus determines the final status from results.
func evaluateOverallStatus(result *ValidationResult) Status {
	// Already set to DOWN if nft failed
	if result.Status == StatusDown {
		return StatusDown
	}

	// Check for critical findings
	hasCritical := false
	hasError := false
	for _, f := range result.Findings {
		if f.Severity == SeverityCritical {
			hasCritical = true
		}
		if f.Severity == SeverityError {
			hasError = true
		}
	}

	if hasCritical {
		return StatusDown
	}

	if hasError {
		return StatusDegraded
	}

	// Check family status
	allProtected := true
	for _, fr := range result.Families {
		if fr.Status != StatusProtected {
			allProtected = false
			break
		}
	}

	if !allProtected {
		return StatusDegraded
	}

	// M81-4: Distinguish PROTECTED from IDLE based on module effective states.
	// If any module is ENFORCING or OBSERVING → PROTECTED.
	// If all enabled modules are IDLE → IDLE.
	// Per derivation algorithm: WARN + active module = PROTECTED, WARN + all idle = IDLE.
	hasActiveModule := false
	if result.Modules.BotGuard != nil && result.Modules.BotGuard.Config == ConfigEnabled {
		if result.Modules.BotGuard.Effective == EffectiveEnforcing || result.Modules.BotGuard.Effective == EffectiveObserving {
			hasActiveModule = true
		}
	}
	if result.Modules.DDoS != nil && result.Modules.DDoS.Config == ConfigEnabled {
		if result.Modules.DDoS.Effective == EffectiveEnforcing {
			hasActiveModule = true
		}
	}
	if result.Modules.LoginMon != nil && result.Modules.LoginMon.Config == ConfigEnabled {
		if result.Modules.LoginMon.Effective == EffectiveEnforcing || result.Modules.LoginMon.Effective == EffectiveObserving {
			hasActiveModule = true
		}
	}
	if result.Modules.Blacklist != nil {
		if result.Modules.Blacklist.Manual.State == "enforcing" {
			hasActiveModule = true
		}
	}

	if hasActiveModule {
		return StatusProtected
	}
	return StatusIdle
}

// computeSummary calculates summary counts.
func computeSummary(result *ValidationResult) SummaryCounts {
	s := SummaryCounts{
		CheckedFamilies: len(result.Families),
	}

	for _, f := range result.Findings {
		s.TotalFindings++
		switch f.Severity {
		case SeverityCritical:
			s.CriticalFindings++
		case SeverityError:
			s.ErrorFindings++
		case SeverityWarn:
			s.WarnFindings++
		}
	}

	for _, fr := range result.Families {
		switch fr.Status {
		case StatusProtected:
			s.ProtectedFams++
		case StatusDegraded:
			s.DegradedFams++
		}
	}

	return s
}

func countFoundChains(found []string) int {
	return len(found)
}

func boolToStatus(b bool, trueMsg, falseMsg string) string {
	if b {
		return trueMsg
	}
	return falseMsg
}
