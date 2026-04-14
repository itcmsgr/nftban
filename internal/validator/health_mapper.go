// =============================================================================
// NFTBan v1.81 - Health Output Mapper
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="health_mapper"
// meta:type="lib"
// meta:version="1.81.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Maps internal ValidationResult to frozen HealthOutput JSON schema"
// meta:inventory.files="internal/validator/health_mapper.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// This mapper is the ONLY path from internal state to JSON output.
// It enforces:
// - vocabulary-approved values only
// - omission rules (disabled modules, kernel-only modules)
// - no nulls
// - schema contract compliance
//
// It MUST NOT contain derivation logic. It projects.
// =============================================================================
package validator

// MapToHealthOutput converts a ValidationResult to the frozen HealthOutput schema.
// This is the single mapping point — all JSON output goes through here.
func MapToHealthOutput(r *ValidationResult) HealthOutput {
	h := HealthOutput{
		SchemaVersion: SchemaVersionCurrent,
		Status:        string(r.Status),
		Timestamp:     r.Timestamp.UTC().Format("2006-01-02T15:04:05Z"),
		ServiceState: ServiceStateJSON{
			Nftband:       string(r.ServiceState.Nftband), // UPPERCASE per spec §5: RUNNING|STOPPED|ERROR
			NftbandDetail: r.ServiceState.NftbandDetail,
		},
		Modules:     mapModules(r.Modules),
		Consistency: mapConsistency(r.ConsistencyOverall),
		Findings:    mapFindings(r.Findings),
		ChainCounts: r.ChainCount,
		Summary:     r.Summary,
	}
	return h
}

// mapModules maps the internal ModuleHealthMap to JSON output.
func mapModules(m ModuleHealthMap) ModulesJSON {
	out := ModulesJSON{}

	if m.BotGuard != nil {
		out.BotGuard = mapModule(m.BotGuard, true) // daemon-dependent
	}
	if m.DDoS != nil {
		out.DDoS = mapModule(m.DDoS, false) // kernel-only
	}
	if m.Portscan != nil {
		out.Portscan = mapModule(m.Portscan, false) // kernel-only
	}
	if m.LoginMon != nil {
		out.LoginMon = mapModule(m.LoginMon, true) // daemon-dependent
	}
	if m.Blacklist != nil {
		out.Blacklist = mapBlacklist(m.Blacklist)
	}

	return out
}

// mapModule maps a single module's health to JSON.
// Enforces omission rules:
// - disabled modules: config only, no other fields
// - kernel-only modules: no runtime field
func mapModule(h *ModuleHealth, daemonDependent bool) *ModuleJSON {
	j := &ModuleJSON{
		Config: string(h.Config),
	}

	// Disabled modules: config only, skip all other axes
	if h.Config == ConfigDisabled {
		return j
	}

	// Structural (always present for enabled modules)
	if h.Structural != "" {
		j.Structural = string(h.Structural)
	}

	// Runtime (only for daemon-dependent modules)
	if daemonDependent && h.Runtime != "" {
		j.Runtime = normalizeRuntime(h.Runtime)
	}

	// Effective (always present for enabled modules)
	if h.Effective != "" {
		j.Effective = string(h.Effective)
	}

	return j
}

// normalizeRuntime maps RuntimeState to lowercase JSON string.
// Internal: RUNNING/STOPPED/ERROR (uppercase enum)
// JSON output: running/stopped/error (lowercase per schema)
func normalizeRuntime(rs RuntimeState) string {
	switch rs {
	case RuntimeRunning:
		return "running"
	case RuntimeStopped:
		return "stopped"
	case RuntimeError:
		return "error"
	default:
		return "error"
	}
}

// mapBlacklist maps the composite blacklist module to JSON.
// Blacklist does NOT follow the 4-axis model.
func mapBlacklist(b *BlacklistHealth) *BlacklistJSON {
	return &BlacklistJSON{
		Manual: BlacklistSubJSON{
			State:   b.Manual.State,
			Entries: b.Manual.Entries,
			Drops:   b.Manual.Drops,
		},
		Feeds: BlacklistSubJSON{
			State:   b.Feeds.State,
			Entries: b.Feeds.Entries,
		},
		Geoban: BlacklistSubJSON{
			State:   b.Geoban.State,
			Entries: b.Geoban.Entries,
		},
	}
}

// mapConsistency returns the consistency block from real evaluation.
// v1.82: replaces the v1.81 stub with actual cross-source verification.
func mapConsistency(consistencyOverall string) ConsistencyJSON {
	if consistencyOverall == "" {
		consistencyOverall = "ok"
	}
	return ConsistencyJSON{
		KernelVsValidator: consistencyOverall,
	}
}

// mapFindings converts internal findings to JSON output format.
func mapFindings(findings []Finding) []FindingJSON {
	out := make([]FindingJSON, 0, len(findings))
	for _, f := range findings {
		out = append(out, FindingJSON{
			Code:        f.Code,
			Severity:    string(f.Severity),
			Component:   f.Component,
			Family:      f.Family,
			Message:     f.Message,
			Remediation: f.Remediation,
		})
	}
	return out
}
