// =============================================================================
// NFTBan v1.190 - OpenMetrics / Prometheus scrape-contract validation (SOS-4)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="metricscontract"
// meta:type="lib"
// meta:version="1.190.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Hermetic OpenMetrics/Prometheus scrape-contract validation harness (SOS-4). Holds no runtime code — it exists so the _test.go gather/parse contract validation has a home package that imports the real metric registrants (internal/metrics, internal/watchdog). The exposition text emitted by the default registry must be parser-valid, type-consistent, duplicate-safe, anchor-double-emit-free, and false-zero-free in the v1.190.0 contract phase."
// meta:inventory.files="internal/metricscontract/doc.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package metricscontract is a test-only home for the v1.190.0 SOS-4
// OpenMetrics scrape-contract validation. It has no runtime API.
package metricscontract
