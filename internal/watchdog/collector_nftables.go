// =============================================================================
// NFTBan v1.0 - nftables Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector_nftables"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Collects nftables metrics via netlink including rules, sets, elements"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/internal/metrics"
)

// NFTablesCollector collects nftables metrics
type NFTablesCollector struct {
	BaseCollector

	mu sync.Mutex

	// Track last apply latency
	lastApplyLatency time.Duration

	// Cache for expensive operations
	lastFullScan     time.Time
	cachedRulesCount int
	cacheDuration    time.Duration

	// v1.34.0: Schema validation
	schemaValidator  *SchemaValidator
	schemaResult     *SchemaResult
	schemaTick       int
	schemaCheckEvery int // default 60 (= 5min at 5s base interval)
}

// NewNFTablesCollector creates a new nftables collector
func NewNFTablesCollector(cacheDuration time.Duration) *NFTablesCollector {
	if cacheDuration == 0 {
		cacheDuration = 30 * time.Second
	}
	return &NFTablesCollector{
		BaseCollector:    NewBaseCollector("nftables"),
		cacheDuration:    cacheDuration,
		schemaValidator:  NewSchemaValidator(),
		schemaCheckEvery: 60, // ~5 min at 5s base interval
	}
}

// Collect gathers nftables metrics
func (c *NFTablesCollector) Collect(ctx context.Context, snapshot *Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// Initialize set elements map
	if snapshot.NFTables.SetElements == nil {
		snapshot.NFTables.SetElements = make(map[string]int)
	}

	// Create nftables connection
	conn, err := nftables.New()
	if err != nil {
		return err
	}
	defer conn.CloseLasting()

	// Collect set sizes (cheap operation)
	c.collectSetSizes(conn, snapshot)

	// Collect rules count (can be expensive, use cache)
	c.collectRulesCount(conn, snapshot)

	// Set last apply latency
	snapshot.NFTables.LastApplyLatency = c.lastApplyLatency.Seconds()

	// v1.34.0: Schema validation (every ~5 min)
	c.schemaTick++
	if c.schemaTick >= c.schemaCheckEvery {
		c.schemaTick = 0
		result := c.schemaValidator.Validate(conn)
		c.schemaResult = &result
		metrics.SetSchemaValidationStatus(!result.Valid)
		metrics.SetSchemaErrorsTotal(len(result.Errors))
		if !result.Valid {
			log.Printf("[SCHEMA] Validation FAILED: %v", result.Errors)
		}
	}

	// Populate schema result into snapshot
	if c.schemaResult != nil {
		snapshot.NFTables.SchemaValid = c.schemaResult.Valid
		snapshot.NFTables.SchemaErrors = c.schemaResult.Errors
	}

	return nil
}

// collectSetSizes counts elements in nftban sets
func (c *NFTablesCollector) collectSetSizes(conn *nftables.Conn, snapshot *Snapshot) {
	// Get tables
	tables, err := conn.ListTables()
	if err != nil {
		return
	}

	totalSets := 0

	for _, table := range tables {
		// Only look at nftban tables
		if table.Name != "nftban" {
			continue
		}

		// List sets in this table
		sets, err := conn.GetSets(table)
		if err != nil {
			continue
		}

		for _, set := range sets {
			totalSets++

			// Get set elements
			elements, err := conn.GetSetElements(set)
			if err != nil {
				continue
			}

			// Key format: family_setname
			family := "ip"
			if table.Family == nftables.TableFamilyIPv6 {
				family = "ip6"
			}
			key := family + "_" + set.Name

			// For interval sets, filter out IntervalEnd markers (kernel returns
			// start+end per entry, so raw len() would double-count)
			if set.Interval {
				count := 0
				for _, elem := range elements {
					if !elem.IntervalEnd {
						count++
					}
				}
				snapshot.NFTables.SetElements[key] = count
			} else {
				snapshot.NFTables.SetElements[key] = len(elements)
			}
		}
	}

	snapshot.NFTables.SetsTotal = totalSets
}

// collectRulesCount counts total rules (cached for performance)
func (c *NFTablesCollector) collectRulesCount(conn *nftables.Conn, snapshot *Snapshot) {
	// Check cache
	if time.Since(c.lastFullScan) < c.cacheDuration && c.cachedRulesCount > 0 {
		snapshot.NFTables.RulesTotal = c.cachedRulesCount
		return
	}

	// Count rules
	rulesTotal := 0
	countersEnabled := false

	tables, err := conn.ListTables()
	if err != nil {
		snapshot.NFTables.RulesTotal = c.cachedRulesCount
		return
	}

	for _, table := range tables {
		chains, err := conn.ListChainsOfTableFamily(table.Family)
		if err != nil {
			continue
		}

		for _, chain := range chains {
			if chain.Table.Name != table.Name {
				continue
			}

			rules, err := conn.GetRules(table, chain)
			if err != nil {
				continue
			}

			rulesTotal += len(rules)

			// Check if any rules have counters
			// This is a simplified check - actual counter detection is complex
			if len(rules) > 0 {
				// In nftables, counters are expressions in rules
				// For simplicity, we assume counters are enabled if we find them
				// A full implementation would inspect rule expressions
			}
		}
	}

	c.cachedRulesCount = rulesTotal
	c.lastFullScan = time.Now()

	snapshot.NFTables.RulesTotal = rulesTotal
	snapshot.NFTables.CountersEnabled = countersEnabled
}

// RecordApplyLatency records the latency of an nft apply operation
// Called by the nft backend after apply operations
func (c *NFTablesCollector) RecordApplyLatency(latency time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastApplyLatency = latency
}

// GetLastApplyLatency returns the last recorded apply latency
func (c *NFTablesCollector) GetLastApplyLatency() time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastApplyLatency
}

// InvalidateCache forces a refresh on next collection
func (c *NFTablesCollector) InvalidateCache() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastFullScan = time.Time{}
}
