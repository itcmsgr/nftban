// =============================================================================
// NFTBan v1.0 - Collector Interface
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector_base"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Base collector interface and common functionality"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

import "context"

// Collector defines the interface for metrics collectors
type Collector interface {
	Name() string
	Collect(ctx context.Context, snapshot *Snapshot) error
	Enabled() bool
	SetEnabled(enabled bool)
}

// BaseCollector provides common functionality for collectors
type BaseCollector struct {
	name    string
	enabled bool
}

// NewBaseCollector creates a new base collector
func NewBaseCollector(name string) BaseCollector {
	return BaseCollector{
		name:    name,
		enabled: true,
	}
}

// Name returns the collector name
func (b *BaseCollector) Name() string {
	return b.name
}

// Enabled returns whether the collector is enabled
func (b *BaseCollector) Enabled() bool {
	return b.enabled
}

// SetEnabled sets the enabled state
func (b *BaseCollector) SetEnabled(enabled bool) {
	b.enabled = enabled
}
