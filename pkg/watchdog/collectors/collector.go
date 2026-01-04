// =============================================================================
// NFTBan v1.0 - Collector Interface
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// =============================================================================

package collectors

import (
	"context"

	"github.com/itcmsgr/nftban/pkg/watchdog"
)

// Collector defines the interface for metrics collectors
type Collector interface {
	// Name returns the collector name
	Name() string

	// Collect gathers metrics and populates the snapshot
	// Only modifies fields relevant to this collector
	Collect(ctx context.Context, snapshot *watchdog.Snapshot) error

	// Enabled returns whether this collector should run
	Enabled() bool

	// SetEnabled enables or disables the collector
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
