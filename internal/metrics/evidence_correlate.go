// =============================================================================
// NFTBan v1.88 - Correlation Engine (M87-6)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_correlate"
// meta:type="package"
// meta:version="1.88.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Evidence correlation engine for metrics Phase 1"
// meta:inventory.files="internal/metrics/evidence_correlate.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Pure function. No exec calls. No side effects. No health derivation.
//
// Correlation is DIAGNOSTIC only:
// - Cannot map to PROTECTED/DEGRADED/DOWN
// - Cannot influence exit codes
// - Cannot produce aggregate system state
// - Cannot be summarized as "healthy/unhealthy"
//
// It answers: "does kernel evidence agree with validator interpretation?"
// =============================================================================
package metrics

// Correlation result values.
const (
	CorrelationMatch              = "match"
	CorrelationExpectedLimitation = "expected_limitation"
	CorrelationWarning            = "warning"
	CorrelationMismatch           = "mismatch"
	CorrelationUnknown            = "unknown"
)

// CorrelateEvidence compares kernel evidence against validator interpretation.
// Pure function — no exec, no side effects, no state mutation.
//
// Inputs:
//   counters: from CollectNamedCounters() — may be nil
//   sets: from CollectSetElements() — may be nil
//   validator: from CollectValidatorSnapshot() — may be nil
//
// Returns: module → correlation result
func CorrelateEvidence(
	counters map[string]CounterValue,
	sets map[string]SetInfo,
	validator *ValidatorSnapshot,
	journal *JournalEvidenceResult,
) map[string]string {
	results := make(map[string]string)

	// If validator is unavailable, all correlations are unknown
	if validator == nil || validator.Unknown {
		results["ddos"] = CorrelationUnknown
		results["botguard"] = CorrelationUnknown
		results["portscan"] = CorrelationUnknown
		results["loginmon"] = CorrelationUnknown
		results["blacklist_manual"] = CorrelationUnknown
		return results
	}

	results["ddos"] = correlateDDoS(counters, validator)
	results["botguard"] = correlateBotGuard(sets, validator)
	results["portscan"] = correlatePortscan(validator)
	results["loginmon"] = correlateLoginMon(journal, validator)
	results["blacklist_manual"] = correlateBlacklistManual(counters, sets, validator)

	return results
}

// correlateDDoS: dedicated counters vs validator effective state.
func correlateDDoS(counters map[string]CounterValue, val *ValidatorSnapshot) string {
	if counters == nil {
		return CorrelationUnknown
	}

	ddosCounterKeys := []string{
		"ip:input_ct_ssh_drop", "ip:input_ct_http_drop", "ip:input_ct_mail_drop",
		"ip:input_syn_rate_exceeded", "ip6:input_syn_prefix_drop",
	}

	hasEvidence := false
	for _, key := range ddosCounterKeys {
		if cv, ok := counters[key]; ok && cv.Packets > 0 {
			hasEvidence = true
			break
		}
	}

	valState := val.Modules["ddos"]

	switch {
	case hasEvidence && valState == "enforcing":
		return CorrelationMatch
	case !hasEvidence && (valState == "idle" || valState == ""):
		return CorrelationMatch
	case hasEvidence && (valState == "idle" || valState == ""):
		return CorrelationMismatch
	case !hasEvidence && valState == "enforcing":
		// Validator says enforcing but counters are zero — possible counter reset
		return CorrelationWarning
	default:
		return CorrelationUnknown
	}
}

// correlateBotGuard: enforcement set population vs validator state.
func correlateBotGuard(sets map[string]SetInfo, val *ValidatorSnapshot) string {
	if sets == nil {
		return CorrelationUnknown
	}

	// If any relevant enforcement set is Unknown, correlation is unknown
	enforcementSets := []string{"ip:http_bot_ban", "ip:http_bot_grey", "ip:http_bot_emergency"}
	for _, key := range enforcementSets {
		if si, ok := sets[key]; ok && si.Unknown {
			return CorrelationUnknown
		}
	}

	hasEvidence := false
	for _, key := range enforcementSets {
		if si, ok := sets[key]; ok && si.Exists && si.Count > 0 {
			hasEvidence = true
			break
		}
	}

	valState := val.Modules["botguard"]

	switch {
	case hasEvidence && (valState == "enforcing" || valState == "observing"):
		return CorrelationMatch
	case !hasEvidence && (valState == "idle" || valState == ""):
		return CorrelationMatch
	case hasEvidence && (valState == "idle" || valState == ""):
		return CorrelationMismatch
	default:
		return CorrelationUnknown
	}
}

// correlatePortscan: structural only, no enforcement counter.
func correlatePortscan(_ *ValidatorSnapshot) string {
	// Portscan has no dedicated enforcement counter.
	// Cannot prove enforcement from kernel metrics.
	return CorrelationExpectedLimitation
}

// correlateLoginMon: v1.88 uses journal evidence for LoginMon activity.
// LoginMon uses shared blacklist sets, so counter evidence is not attributable.
// Journal evidence (ban/login_failed events) is the primary signal.
func correlateLoginMon(journal *JournalEvidenceResult, val *ValidatorSnapshot) string {
	if journal == nil || journal.Unknown {
		return CorrelationUnknown
	}

	valState := val.Modules["loginmon"]

	switch {
	case journal.LoginMonActive && journal.LoginMonBans > 0 && valState == "idle":
		// Bans happening but validator says idle — shared counter limitation
		return CorrelationWarning
	case journal.LoginMonActive && journal.LoginMonBans > 0:
		// Bans happening and validator is not idle — evidence agrees
		return CorrelationMatch
	case !journal.LoginMonActive && (valState == "idle" || valState == ""):
		// No activity, validator idle — evidence agrees
		return CorrelationMatch
	case journal.LoginMonActive && journal.LoginMonBans == 0:
		// Events detected but no bans — observing, not enforcing.
		// Evidence is partial (events ≠ enforcement), attribution indirect.
		return CorrelationWarning
	default:
		return CorrelationUnknown
	}
}

// correlateBlacklistManual: elements + drops vs validator state.
func correlateBlacklistManual(
	counters map[string]CounterValue,
	sets map[string]SetInfo,
	val *ValidatorSnapshot,
) string {
	if counters == nil || sets == nil {
		return CorrelationUnknown
	}

	// If the relevant set is Unknown, correlation is unknown
	if si, ok := sets["ip:blacklist_manual_ipv4"]; ok && si.Unknown {
		return CorrelationUnknown
	}

	hasElements := false
	if si, ok := sets["ip:blacklist_manual_ipv4"]; ok && si.Exists && si.Count > 0 {
		hasElements = true
	}

	hasDrops := false
	if cv, ok := counters["ip:input_blacklist_manual_drop"]; ok && cv.Packets > 0 {
		hasDrops = true
	}

	valState := val.Modules["blacklist_manual"]

	switch {
	case hasElements && hasDrops && valState == "enforcing":
		return CorrelationMatch
	case hasElements && !hasDrops && valState == "primed":
		return CorrelationMatch
	case !hasElements && valState == "idle":
		return CorrelationMatch
	case hasElements && hasDrops && valState == "primed":
		return CorrelationWarning
	default:
		return CorrelationUnknown
	}
}
