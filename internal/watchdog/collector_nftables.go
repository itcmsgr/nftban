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

	"github.com/itcmsgr/nftban/internal/constants"
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

	// v1.228.7: set-size sampling is TIERED. `collectSetSizes` was called
	// ungated on every 5s tick under the comment "cheap operation", and it
	// dumps EVERY element of EVERY set purely to take len(). It is not cheap:
	// measured 2026-08-04, daemon CPU tracks TOTAL element count — dns4
	// 188,704 elements -> 113% CPU, ~90% of wall-clock in NETLINK dump, IPC
	// starved to the point `nftban ddos enable` timed out. 84% was SYSTEM time
	// in the kernel set-walk, so switching to GetSetCount would change nothing
	// (setsync/nft_sets.go:338 calls GetSetElements itself).
	//
	// Two populations with different cost and different purpose:
	//   ENFORCEMENT sets (blacklist/whitelist/ports — interval/constant):
	//     correctness-relevant, small, sampled at setInterval.
	//   DYNAMIC rate-limiter sets (kernel-managed, up to `size` = 65535 each):
	//     capacity OBSERVABILITY only, sampled at dynamicSetInterval.
	// Both are cached between samples so the tick rate no longer sets the cost.
	setInterval        time.Duration
	dynamicSetInterval time.Duration
	lastSetScan        time.Time
	lastDynamicSetScan time.Time
	cachedSetElements  map[string]int
	cachedDynamicSets  map[string]int
	cachedSetsTotal    int

	// v1.34.0: Schema validation
	schemaValidator  *SchemaValidator
	schemaResult     *SchemaResult
	schemaTick       int
	schemaCheckEvery int // default 60 (= 5min at 5s base interval)
}

// NewNFTablesCollector creates a new nftables collector
func NewNFTablesCollector(cacheDuration time.Duration) *NFTablesCollector {
	return NewNFTablesCollectorWithIntervals(cacheDuration, 0, 0)
}

// NewNFTablesCollectorWithIntervals builds the collector with explicit sampling
// intervals. setInterval is the config's NFTSetInterval, which was declared,
// defaulted, clamped and unit-tested but NEVER READ outside tests — a dead knob
// (only NFTRulesetInterval was wired). v1.228.7 wires it.
func NewNFTablesCollectorWithIntervals(cacheDuration, setInterval, dynamicSetInterval time.Duration) *NFTablesCollector {
	if cacheDuration == 0 {
		cacheDuration = 30 * time.Second
	}
	if setInterval <= 0 {
		setInterval = constants.WatchdogNFTSetInterval
	}
	if dynamicSetInterval <= 0 {
		// Dynamic limiter occupancy is an observability signal, not a
		// correctness one: it feeds fill-ratio reporting, and a limiter cannot
		// change category between samples. Sampling it at the enforcement-set
		// rate is what made the walk dominate the daemon.
		dynamicSetInterval = constants.WatchdogNFTDynamicSetInterval
	}
	if dynamicSetInterval < setInterval {
		dynamicSetInterval = setInterval
	}
	return &NFTablesCollector{
		BaseCollector:      NewBaseCollector("nftables"),
		cacheDuration:      cacheDuration,
		setInterval:        setInterval,
		dynamicSetInterval: dynamicSetInterval,
		cachedSetElements:  make(map[string]int),
		cachedDynamicSets:  make(map[string]int),
		schemaValidator:    NewSchemaValidator(),
		schemaCheckEvery:   60, // ~5 min at 5s base interval
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

	// v1.228.7: NOT a cheap operation — see collectSetSizes. Tiered + cached.
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

	// Decide, ONCE per call, which populations are due. Neither is walked on a
	// tick where its interval has not elapsed; the cached counts are published
	// instead, so the reported metric stays continuous while the netlink dump
	// rate is decoupled from the 5s watchdog tick.
	now := time.Now()
	scanEnforcement := now.Sub(c.lastSetScan) >= c.setInterval
	scanDynamic := now.Sub(c.lastDynamicSetScan) >= c.dynamicSetInterval

	if !scanEnforcement && !scanDynamic {
		c.publishCachedSetElements(snapshot)
		return
	}

	for _, table := range tables {
		// Only look at nftban tables
		if table.Name != "nftban" {
			continue
		}

		// List sets in this table (metadata only — no element dump)
		sets, err := conn.GetSets(table)
		if err != nil {
			continue
		}

		for _, set := range sets {
			totalSets++

			// Key format: family_setname
			family := "ip"
			if table.Family == nftables.TableFamilyIPv6 {
				family = "ip6"
			}
			key := family + "_" + set.Name

			// THE COST GATE. A dynamic set is a kernel-managed rate limiter
			// holding up to `size` (65535) elements; enumerating it is the
			// expensive walk. Skip it unless its own, longer interval is due,
			// and serve the last known value meanwhile.
			if set.Dynamic {
				if !scanDynamic {
					if cached, ok := c.cachedDynamicSets[key]; ok {
						snapshot.NFTables.SetElements[key] = cached
					}
					continue
				}
			} else if !scanEnforcement {
				if cached, ok := c.cachedSetElements[key]; ok {
					snapshot.NFTables.SetElements[key] = cached
				}
				continue
			}

			elements, err := conn.GetSetElements(set)
			if err != nil {
				// A failed dump is NOT zero. Keep the last known value rather
				// than publishing a false empty (an absent set and an
				// unreadable set are different states).
				if cached, ok := c.cachedSetElements[key]; ok {
					snapshot.NFTables.SetElements[key] = cached
				} else if cached, ok := c.cachedDynamicSets[key]; ok {
					snapshot.NFTables.SetElements[key] = cached
				}
				continue
			}

			count := len(elements)
			// For interval sets, filter out IntervalEnd markers (kernel returns
			// start+end per entry, so raw len() would double-count)
			if set.Interval {
				count = 0
				for _, elem := range elements {
					if !elem.IntervalEnd {
						count++
					}
				}
			}
			snapshot.NFTables.SetElements[key] = count
			if set.Dynamic {
				c.cachedDynamicSets[key] = count
			} else {
				c.cachedSetElements[key] = count
			}
		}
	}

	if scanEnforcement {
		c.lastSetScan = now
	}
	if scanDynamic {
		c.lastDynamicSetScan = now
	}
	c.cachedSetsTotal = totalSets
	snapshot.NFTables.SetsTotal = totalSets
}

// publishCachedSetElements serves the last known counts on a tick where no
// population is due. Publishing nothing would make consumers read "absent",
// which is a different claim from "unchanged".
func (c *NFTablesCollector) publishCachedSetElements(snapshot *Snapshot) {
	for k, v := range c.cachedSetElements {
		snapshot.NFTables.SetElements[k] = v
	}
	for k, v := range c.cachedDynamicSets {
		snapshot.NFTables.SetElements[k] = v
	}
	snapshot.NFTables.SetsTotal = c.cachedSetsTotal
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
