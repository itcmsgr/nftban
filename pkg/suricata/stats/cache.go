package stats

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// SIDStats holds statistics for a single SID
type SIDStats struct {
	SID           string    `json:"sid"`
	Category      string    `json:"category"`
	Signature     string    `json:"signature"`
	TriggerCount  int       `json:"trigger_count"`
	LastTrigger   time.Time `json:"last_trigger"`
	FirstTrigger  time.Time `json:"first_trigger"`
	UniqueSources map[string]bool `json:"-"` // Not serialized
	SourceCount   int       `json:"source_count"`
	SourceIPs     []string  `json:"source_ips,omitempty"` // Top 10 for display
}

// Cache holds in-memory SID statistics
type Cache struct {
	mu            sync.RWMutex
	stats         map[string]*SIDStats // Key: SID
	snapshotPath  string
	lastSnapshot  time.Time
}

// NewCache creates a new statistics cache
func NewCache() (*Cache, error) {
	cfg := nftbanconf.MustLoad()
	snapshotPath := filepath.Join(cfg.ConfigDir, "suricata/cache/sid-stats.json")

	cache := &Cache{
		stats:        make(map[string]*SIDStats),
		snapshotPath: snapshotPath,
	}

	// Load existing snapshot if available
	if err := cache.Load(); err != nil {
		fmt.Printf("No existing snapshot found (starting fresh): %v\n", err)
	}

	return cache, nil
}

// RecordTrigger records a SID trigger event
func (c *Cache) RecordTrigger(sid, category, signature, sourceIP string, timestamp time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()

	stats, exists := c.stats[sid]
	if !exists {
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

	// Track unique sources
	if sourceIP != "" {
		stats.UniqueSources[sourceIP] = true
		stats.SourceCount = len(stats.UniqueSources)
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

	// Write to file
	if err := os.WriteFile(c.snapshotPath, data, 0644); err != nil {
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

	// Rebuild cache
	c.stats = make(map[string]*SIDStats)
	for _, stats := range snapshot {
		// Reconstruct UniqueSources map
		stats.UniqueSources = make(map[string]bool)
		for _, ip := range stats.SourceIPs {
			stats.UniqueSources[ip] = true
		}
		c.stats[stats.SID] = stats
	}

	fmt.Printf("Cache snapshot loaded: %s (%d SIDs)\n", c.snapshotPath, len(snapshot))
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
