// =============================================================================
// NFTBan v1.87 - Evidence Types (Phase 1 Canonical Model)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_types"
// meta:type="package"
// meta:version="1.87.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Canonical evidence types for metrics Phase 1"
// meta:inventory.files="internal/metrics/evidence_types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Types only. No collection logic. No rendering logic.
// Metrics report evidence; validator reports interpretation.
// =============================================================================
package metrics

import "time"

// CounterValue holds a single named counter's packets and bytes.
type CounterValue struct {
	Packets int64 `json:"packets"`
	Bytes   int64 `json:"bytes"`
}

// NamedCountersResult holds all named counters from a single collection.
// Keys use stable format: "<family>:<counter_name>" (e.g. "ip:input_ct_ssh_drop").
// An empty Counters map is valid (no counters found, not an error).
// A nil result with non-nil error means collection failed.
type NamedCountersResult struct {
	CollectedAt time.Time               `json:"collected_at"`
	Counters    map[string]CounterValue `json:"counters"`
}
