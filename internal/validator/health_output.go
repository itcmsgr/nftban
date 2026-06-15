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
	SchemaVersion string           `json:"schema_version"`
	Status        string           `json:"status"`
	Timestamp     string           `json:"timestamp"`
	ServiceState  ServiceStateJSON `json:"service_state"`
	Modules       ModulesJSON      `json:"modules"`
	Consistency   ConsistencyJSON  `json:"consistency"`
	Findings      []FindingJSON    `json:"findings"`
	ChainCounts   ChainCounts      `json:"chain_counts"`
	Summary       SummaryCounts    `json:"summary"`
	// v1.84 SCHEMA-UNFREEZE counters contract (additive).
	CountersPhase string        `json:"counters_phase"`     // "contract" (v1.190.0) | "populated" (v1.191.0); the anti-false-zero gate
	Counters      *CountersJSON `json:"counters,omitempty"` // nil/ABSENT until v1.191.0 populates — absent ≠ zero (no false-zero dashboards)
	// v1.84 NFT counting-model contract view (additive; nil/ABSENT until v1.191.0).
	NFT *NFTCountersJSON `json:"nft,omitempty"` // interpreted JSON VIEW over existing nft named counters — NOT a new Prometheus family (SOS-2 Option A)
}

// NFTCountersJSON is the v1.84 NFT counting-model JSON view. It is an INTERPRETED
// projection over the EXISTING nft named counters (Prometheus
// nftban_nft_named_counter_packets_total{family,counter} / _bytes_total) — it does
// NOT introduce a parallel Prometheus metric (SOS-2 Option A: no double-count). In
// v1.190.0 the pointer is always nil → the "nft" object is ABSENT (omitempty);
// population begins v1.191.0 from the same named-counter / nft-JSON source.
type NFTCountersJSON struct {
	Anchors []NFTAnchorJSON `json:"anchors,omitempty"` // phase-boundary view; see NFTAnchorJSON
}

// NFTAnchorJSON is one anchor phase-boundary counter (v1.84 contract).
// Anchors (anchor_hygiene→…→anchor_final, both ip + ip6 tables, comment
// NFTBAN_ANCHOR:*) are PHASE-BOUNDARY / pipeline-continuity counters — they answer
// "did traffic reach this firewall phase?" They are NOT accept/drop verdict counters
// and MUST NOT be summed into total_input_accept / total_input_drop. They do not
// change health status in v1.190.0.
//
// Family is NORMALIZED per SOS-3 (OPTION_1_NORMALIZE_JSON_KEEP_PROMETHEUS_COMPAT):
// the kernel/Prometheus family "ip"/"ip6" is mapped to JSON "ipv4"/"ipv6" so the
// entire 1.84.0 JSON contract speaks ONE vocabulary (ipv4|ipv6|inet|unknown). The
// Prometheus label nft_named_counter_*{family="ip"|"ip6"} is left UNCHANGED for
// compatibility; the bridge is documented: Prometheus ip == JSON ipv4, ip6 == ipv6.
type NFTAnchorJSON struct {
	Family  string `json:"family"`  // ipv4|ipv6 (normalized from nft ip/ip6); anchors never inet/unknown — unknown ⇒ collection defect
	Anchor  string `json:"anchor"`  // anchor_hygiene|anchor_trusted|anchor_ban|anchor_established|anchor_detect|anchor_service|anchor_final
	Packets uint64 `json:"packets"` // from the named counter (real value once populated v1.191.0)
	Bytes   uint64 `json:"bytes"`   // from the named counter
}

// NFT family-vocabulary constants — the SINGLE JSON vocabulary (SOS-3).
// JSON output uses ONLY these; raw nft table families "ip"/"ip6" never appear in JSON.
const (
	FamilyIPv4    = "ipv4" // JSON; bridges Prometheus family="ip"
	FamilyIPv6    = "ipv6" // JSON; bridges Prometheus family="ip6"
	FamilyInet    = "inet" // table-level only (genuinely-inet rules); never fake-split
	FamilyUnknown = "unknown"
)

// NormalizeNFTFamily maps a raw nftables table family to the canonical JSON family
// vocabulary (SOS-3 OPTION_1). nft "ip"→"ipv4", "ip6"→"ipv6", "inet"→"inet";
// anything else (incl. empty) → "unknown". This is the ONLY bridge between the
// Prometheus named-counter label space (ip/ip6, unchanged for compat) and the JSON
// 1.84.0 contract (ipv4/ipv6/inet/unknown). For per-IP/anchor counters a result of
// "unknown" signals a classification/collection defect (v1.191 tests assert absence).
func NormalizeNFTFamily(nftFamily string) string {
	switch nftFamily {
	case "ip", "ipv4":
		return FamilyIPv4
	case "ip6", "ipv6":
		return FamilyIPv6
	case "inet":
		return FamilyInet
	default:
		return FamilyUnknown
	}
}

// CountersJSON is the v1.84 counters CONTRACT. In v1.190.0 the pointer is always
// nil → the "counters" object is ABSENT from JSON (omitempty). The contract exists
// in the type system / schema; population begins v1.191.0 (which also flips
// counters_phase → "populated"). Absent is deliberately NOT zero so consumers do
// not read "nothing happened" from contract-only output.
type CountersJSON struct {
	BotScan   *BotScanCountersJSON   `json:"botscan,omitempty"`
	BotGuard  *BotGuardCountersJSON  `json:"botguard,omitempty"`
	Whitelist *WhitelistCountersJSON `json:"whitelist,omitempty"`
}

// FamilyCounts is an IP-backed counter split by address family (v1.84 contract;
// DESIGN_AMENDMENT_V1_190_IP_FAMILY). In Prometheus this is the low-cardinality
// label family="ipv4|ipv6|inet|unknown"; in JSON it is these omitempty sub-fields.
// Semantics:
//   - PER-IP counters (bans/signals/crawler_verify/etc.): use ipv4 / ipv6 only.
//     `unknown` here signals a classification BUG (a banned IP is always v4 or v6);
//     `inet` is NOT valid for per-IP counters.
//   - TABLE-LEVEL counters (nft forward/output from an inet chain): use `inet`.
//
// Never fake-split a genuinely-inet rule into ipv4/ipv6. omitempty → absent in the
// contract phase (no false-zero) and zero families omitted once populated.
type FamilyCounts struct {
	IPv4    uint64 `json:"ipv4,omitempty"`
	IPv6    uint64 `json:"ipv6,omitempty"`
	Inet    uint64 `json:"inet,omitempty"`    // table-level only (e.g. inet-chain forward/output)
	Unknown uint64 `json:"unknown,omitempty"` // last-resort; on per-IP counters indicates a classification gap
}

// BotScanCountersJSON — populated v1.191.0 (BotScan processor state).
// IP-backed counters carry family; files_deferred is per-FILE (no IP → no family).
type BotScanCountersJSON struct {
	ScannedEntries FamilyCounts `json:"scanned_entries"`
	Matched        FamilyCounts `json:"matched"`        // also by category in Prometheus
	Signals        FamilyCounts `json:"signals"`        // also ban vs grey in Prometheus
	Bans           FamilyCounts `json:"bans"`           // also by reason/category in Prometheus
	CrawlerVerify  FamilyCounts `json:"crawler_verify"` // also ok/bad/timeout/cachehit in Prometheus
	FilesDeferred  uint64       `json:"files_deferred"` // per-file rotation/budget — NOT IP-backed, no family
}

// BotGuardCountersJSON — populated v1.191.0 (counters absent in BotGuard today).
type BotGuardCountersJSON struct {
	Decisions     FamilyCounts `json:"decisions"`      // IP-backed (also by decision in Prometheus)
	EventbusDrops uint64       `json:"eventbus_drops"` // not IP-backed → no family
}

// WhitelistCountersJSON — populated v1.191.0 (today only gauges exist).
type WhitelistCountersJSON struct {
	Changes FamilyCounts `json:"changes"` // IP-backed (also by op add/remove/expire in Prometheus)
}

// ServiceStateJSON is the JSON representation of daemon and timer state.
type ServiceStateJSON struct {
	Nftband       string `json:"nftband"`                  // RUNNING|STOPPED|ERROR
	NftbandDetail string `json:"nftband_detail,omitempty"` // raw systemctl output
	TimerCount    int    `json:"timer_count"`              // v1.83: active nftban-* timer count
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
	Config     string `json:"config"`               // enabled|disabled (always present)
	Structural string `json:"structural,omitempty"` // present|missing (omitted if disabled)
	Runtime    string `json:"runtime,omitempty"`    // running|stopped (omitted if not daemon-dependent)
	Effective  string `json:"effective,omitempty"`  // enforcing|observing|idle (omitted if disabled)
	// NOTE: the v1.183 input-readability axis is intentionally NOT a field here — the
	// M81-6 health-output schema is frozen (1.83.0). Enabled-but-starved is surfaced via
	// the CodeLoginMonNoInput finding instead; a first-class input axis awaits SCHEMA-UNFREEZE.
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
	State   string `json:"state"`             // enforcing|primed|idle|loaded|stale|degraded|disabled
	Entries int    `json:"entries,omitempty"` // element count (omitted if 0 or not applicable)
	Drops   int64  `json:"drops,omitempty"`   // counter value (omitted if 0 or not attributable)
}

// ConsistencyJSON holds cross-source agreement status.
// Stub for v1.81.0 — expanded in v1.82.
type ConsistencyJSON struct {
	KernelVsValidator string `json:"kernel_vs_validator"` // ok|mismatch
}

// FindingJSON is a single validation finding in the output.
type FindingJSON struct {
	Code        string `json:"code"`
	Severity    string `json:"severity"` // info|warn|error|critical
	Component   string `json:"component"`
	Family      string `json:"family,omitempty"`
	Message     string `json:"message"`
	Remediation string `json:"remediation,omitempty"`
}
