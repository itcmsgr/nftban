// =============================================================================
// NFTBan - Suricata SID Statistics Cache
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cache"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="In-memory SID statistics with LRU eviction and disk persistence"
// meta:input="SID trigger events"
// meta:output="Statistics per SID"
// meta:depends="github.com/itcmsgr/nftban/internal/nftbanconf,github.com/itcmsgr/nftban/internal/safety"
// meta:inventory.files="/var/lib/nftban/suricata/cache/sid-stats.json"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package stats

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/safety"
)

// SIDStats holds statistics for a single SID
type SIDStats struct {
	SID           string          `json:"sid"`
	Category      string          `json:"category"`
	Signature     string          `json:"signature"`
	TriggerCount  int             `json:"trigger_count"`
	LastTrigger   time.Time       `json:"last_trigger"`
	FirstTrigger  time.Time       `json:"first_trigger"`
	UniqueSources map[string]bool `json:"-"` // Not serialized (capped in memory)
	SourceCount   int             `json:"source_count"`
	SourceIPs     []string        `json:"source_ips,omitempty"` // Top 10 for display
}

// Cache holds in-memory SID statistics
// Implements bounded memory via caps on SIDs and sources per SID.
// Protects against CWE-400 (Uncontrolled Resource Consumption).
type Cache struct {
	mu           sync.RWMutex
	stats        map[string]*SIDStats // Key: SID
	snapshotPath string
	lastSnapshot time.Time

	// Memory limits (CWE-400 mitigation)
	maxSIDs          int
	maxSourcesPerSID int
}

// NewCache creates a new statistics cache with bounded memory
func NewCache() (*Cache, error) {
	cfg := nftbanconf.MustLoad()
	// v1.175 FHS-SMELL-SIDSTATS: the snapshot lives under DataDir (/var/lib/nftban),
	// NOT ConfigDir (/etc). FHS reserves /etc for configuration; this is a mutable
	// runtime cache rewritten on every auto-save tick. Write atomicity is unchanged
	// (still safety.SafeWriteFile, v1.171) — only the location moved.
	snapshotPath := filepath.Join(cfg.DataDir, "suricata/cache/sid-stats.json")
	// Migrate a pre-v1.175 snapshot from the old /etc location on first startup.
	migrateLegacySnapshot(filepath.Join(cfg.ConfigDir, "suricata/cache/sid-stats.json"), snapshotPath)

	limits := safety.GetMemoryLimits()

	cache := &Cache{
		stats:            make(map[string]*SIDStats),
		snapshotPath:     snapshotPath,
		maxSIDs:          limits.StatsMaxSIDs,
		maxSourcesPerSID: limits.StatsMaxSourcesPerSID,
	}

	// Load existing snapshot if available
	if err := cache.Load(); err != nil {
		fmt.Printf("No existing snapshot found (starting fresh): %v\n", err)
	}

	return cache, nil
}

// migrateLegacySnapshot moves the pre-v1.175 SID-stats snapshot from its old
// location under /etc (ConfigDir) to the new location under /var/lib (DataDir)
// on first startup. Best-effort: any failure leaves the old file in place and the
// subsequent Load() simply starts fresh — no panic, no data-integrity risk (the
// cache rebuilds from live SID-trigger events). v1.175 FHS-SMELL-SIDSTATS.
func migrateLegacySnapshot(oldPath, newPath string) {
	if oldPath == newPath {
		return
	}
	// New snapshot already present → nothing to migrate.
	if _, err := os.Stat(newPath); err == nil {
		return
	}
	// No legacy snapshot → nothing to do (fresh install / already migrated).
	if _, err := os.Stat(oldPath); err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(newPath), 0750); err != nil {
		return
	}
	// Best-effort rename. If it fails (e.g. EXDEV when /etc and /var are separate
	// mounts), leave the old file in place; Load() then starts fresh and the cache
	// rebuilds from live SID-trigger events. We deliberately do NOT read+copy as a
	// fallback: it would add an os.ReadFile(variable) file-inclusion surface
	// (gosec G304) for a non-critical, self-rebuilding cache — not worth it.
	_ = os.Rename(oldPath, newPath)
}

// RecordTrigger records a SID trigger event
func (c *Cache) RecordTrigger(sid, category, signature, sourceIP string, timestamp time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()

	stats, exists := c.stats[sid]
	if !exists {
		// Check SID capacity before adding
		if len(c.stats) >= c.maxSIDs {
			// Evict oldest SID (by LastTrigger)
			c.evictOldestSIDLocked()
		}

		stats = &SIDStats{
			SID:           sid,
			Category:      category,
			Signature:     signature,
			UniqueSources: make(map[string]bool),
			FirstTrigger:  timestamp,
		}
		c.stats[sid] = stats
	}

	// Update counters
	stats.TriggerCount++
	stats.LastTrigger = timestamp
	if stats.FirstTrigger.IsZero() || timestamp.Before(stats.FirstTrigger) {
		stats.FirstTrigger = timestamp
	}

	// Track unique sources with cap
	if sourceIP != "" {
		// Only add if under cap or already exists
		if _, exists := stats.UniqueSources[sourceIP]; !exists {
			if len(stats.UniqueSources) < c.maxSourcesPerSID {
				stats.UniqueSources[sourceIP] = true
			}
			// Note: if at cap, we don't add new sources but still count triggers
		}
		stats.SourceCount = len(stats.UniqueSources)
	}
}

// evictOldestSIDLocked removes the oldest SID by LastTrigger (must be called with lock held)
func (c *Cache) evictOldestSIDLocked() {
	if len(c.stats) == 0 {
		return
	}

	var oldestSID string
	var oldestTime time.Time
	first := true

	for sid, stats := range c.stats {
		if first || stats.LastTrigger.Before(oldestTime) {
			oldestSID = sid
			oldestTime = stats.LastTrigger
			first = false
		}
	}

	if oldestSID != "" {
		delete(c.stats, oldestSID)
	}
}

// GetSIDStats returns statistics for a specific SID
func (c *Cache) GetSIDStats(sid string) (*SIDStats, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	stats, exists := c.stats[sid]
	if !exists {
		return nil, false
	}

	// Make a copy with top source IPs
	copy := *stats
	copy.SourceIPs = c.getTopSourceIPs(stats.UniqueSources, 10)
	return &copy, true
}

// GetTopSIDs returns top N SIDs by trigger count
func (c *Cache) GetTopSIDs(n int) []*SIDStats {
	c.mu.RLock()
	defer c.mu.RUnlock()

	// Convert to slice
	statsList := make([]*SIDStats, 0, len(c.stats))
	for _, stats := range c.stats {
		copy := *stats
		copy.SourceIPs = c.getTopSourceIPs(stats.UniqueSources, 10)
		statsList = append(statsList, &copy)
	}

	// Sort by trigger count (descending)
	sort.Slice(statsList, func(i, j int) bool {
		return statsList[i].TriggerCount > statsList[j].TriggerCount
	})

	// Return top N
	if n > 0 && n < len(statsList) {
		return statsList[:n]
	}
	return statsList
}

// GetRecentSIDs returns SIDs triggered in the last duration
func (c *Cache) GetRecentSIDs(duration time.Duration) []*SIDStats {
	c.mu.RLock()
	defer c.mu.RUnlock()

	cutoff := time.Now().Add(-duration)
	recent := make([]*SIDStats, 0)

	for _, stats := range c.stats {
		if stats.LastTrigger.After(cutoff) {
			copy := *stats
			copy.SourceIPs = c.getTopSourceIPs(stats.UniqueSources, 10)
			recent = append(recent, &copy)
		}
	}

	// Sort by last trigger (most recent first)
	sort.Slice(recent, func(i, j int) bool {
		return recent[i].LastTrigger.After(recent[j].LastTrigger)
	})

	return recent
}

// GetAllStats returns all SID statistics
func (c *Cache) GetAllStats() []*SIDStats {
	return c.GetTopSIDs(-1) // -1 means all
}

// GetSize returns the number of tracked SIDs
func (c *Cache) GetSize() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.stats)
}

// GetUniqueSIDs returns the number of unique SIDs
func (c *Cache) GetUniqueSIDs() int {
	return c.GetSize()
}

// GetTotalTriggers returns total trigger count across all SIDs
func (c *Cache) GetTotalTriggers() int {
	c.mu.RLock()
	defer c.mu.RUnlock()

	total := 0
	for _, stats := range c.stats {
		total += stats.TriggerCount
	}
	return total
}

// GetUniqueSources returns total unique source IPs across all SIDs
func (c *Cache) GetUniqueSources() int {
	c.mu.RLock()
	defer c.mu.RUnlock()

	allSources := make(map[string]bool)
	for _, stats := range c.stats {
		for ip := range stats.UniqueSources {
			allSources[ip] = true
		}
	}
	return len(allSources)
}

// getTopSourceIPs returns top N source IPs from map
func (c *Cache) getTopSourceIPs(sources map[string]bool, n int) []string {
	ips := make([]string, 0, len(sources))
	for ip := range sources {
		ips = append(ips, ip)
	}

	// Sort alphabetically for consistent output
	sort.Strings(ips)

	// Return top N
	if n > 0 && n < len(ips) {
		return ips[:n]
	}
	return ips
}

// Save writes cache snapshot to disk
func (c *Cache) Save() error {
	c.mu.RLock()
	defer c.mu.RUnlock()

	// Ensure directory exists
	dir := filepath.Dir(c.snapshotPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create cache directory: %w", err)
	}

	// Convert stats to serializable format
	snapshot := make([]*SIDStats, 0, len(c.stats))
	for _, stats := range c.stats {
		copy := *stats
		copy.SourceCount = len(stats.UniqueSources)
		copy.SourceIPs = c.getTopSourceIPs(stats.UniqueSources, 100) // Save top 100
		snapshot = append(snapshot, &copy)
	}

	// Marshal to JSON
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal cache: %w", err)
	}

	// Write to file. v1.171 §4.2: atomic (temp+fsync+rename, random temp) via
	// the gold helper so a crash mid-write or a concurrent Load() can never see
	// a truncated/torn JSON snapshot (the dir was MkdirAll'd above).
	if err := safety.SafeWriteFile(c.snapshotPath, data, 0644); err != nil {
		return fmt.Errorf("failed to write snapshot: %w", err)
	}

	c.lastSnapshot = time.Now()
	fmt.Printf("Cache snapshot saved: %s (%d SIDs)\n", c.snapshotPath, len(snapshot))
	return nil
}

// Load reads cache snapshot from disk
func (c *Cache) Load() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Read snapshot file
	data, err := os.ReadFile(c.snapshotPath)
	if err != nil {
		return err
	}

	// Parse JSON
	var snapshot []*SIDStats
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return fmt.Errorf("failed to unmarshal snapshot: %w", err)
	}

	// Rebuild cache with caps
	c.stats = make(map[string]*SIDStats)

	// Sort by LastTrigger to keep most recent if we need to cap
	sort.Slice(snapshot, func(i, j int) bool {
		return snapshot[i].LastTrigger.After(snapshot[j].LastTrigger)
	})

	for _, stats := range snapshot {
		// Cap total SIDs
		if len(c.stats) >= c.maxSIDs {
			break
		}

		// Reconstruct UniqueSources map with cap
		stats.UniqueSources = make(map[string]bool)
		for i, ip := range stats.SourceIPs {
			if i >= c.maxSourcesPerSID {
				break
			}
			stats.UniqueSources[ip] = true
		}
		stats.SourceCount = len(stats.UniqueSources)
		c.stats[stats.SID] = stats
	}

	fmt.Printf("Cache snapshot loaded: %s (%d SIDs)\n", c.snapshotPath, len(c.stats))
	return nil
}

// Clear removes all statistics
func (c *Cache) Clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.stats = make(map[string]*SIDStats)
}

// StartAutoSave starts periodic snapshot saving
func (c *Cache) StartAutoSave(interval time.Duration) {
	ticker := time.NewTicker(interval)
	go func() {
		for range ticker.C {
			if err := c.Save(); err != nil {
				fmt.Printf("Auto-save failed: %v\n", err)
			}
		}
	}()
}

// GetStats returns memory usage statistics for monitoring
func (c *Cache) GetStats() map[string]int {
	c.mu.RLock()
	defer c.mu.RUnlock()

	totalSources := 0
	for _, stats := range c.stats {
		totalSources += len(stats.UniqueSources)
	}

	return map[string]int{
		"sids":                len(c.stats),
		"max_sids":            c.maxSIDs,
		"total_sources":       totalSources,
		"max_sources_per_sid": c.maxSourcesPerSID,
	}
}
