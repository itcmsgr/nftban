// =============================================================================
// NFTBan v1.32.0 - Set Element Counters
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="set_counters"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-21"
// meta:description="In-memory per-set element counters for huge set management"
// meta:inventory.files="/run/nftban/set_counts.json"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Maintains daemon-owned per-set element counts to eliminate
// expensive O(n) kernel nft list set calls for counting.
// Counters are updated atomically on every add/delete/flush/replace.
// A cache file in /run/nftban/set_counts.json is written for
// shell exporter and CLI consumption.
//
// Design: DESIGN_HUGE_SET_COUNTING_ARCHITECTURE.md
// =============================================================================

package stats

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

// Scale levels for set size classification
const (
	ScaleNormal    = "NORMAL"         // 0 – 9,999
	ScaleLarge     = "LARGE"          // 10,000 – 49,999
	ScaleVeryLarge = "VERY_LARGE"     // 50,000 – 99,999
	ScaleHuge      = "HUGE"           // 100,000 – 249,999
	ScaleExtreme   = "EXTREME"        // 250,000 – 499,999
	ScaleCritical  = "CRITICAL_SCALE" // 500,000+
)

// Scale level numeric values for Prometheus export
const (
	ScaleNumNormal    = 0
	ScaleNumLarge     = 1
	ScaleNumVeryLarge = 2
	ScaleNumHuge      = 3
	ScaleNumExtreme   = 4
	ScaleNumCritical  = 5
)

// Thresholds for scale levels
const (
	ThresholdLarge     = 10_000
	ThresholdVeryLarge = 50_000
	ThresholdHuge      = 100_000
	ThresholdExtreme   = 250_000
	ThresholdCritical  = 500_000
)

// SetCounters tracks per-set element counts in daemon memory.
// Updated atomically on every add/delete/flush/replace operation.
type SetCounters struct {
	mu       sync.RWMutex
	counts   map[string]*atomic.Int64 // key: setName (e.g. "blacklist_ipv4")
	lastSync map[string]time.Time     // last kernel reconciliation per set

	// Trend tracking: snapshot counts at window boundaries
	trendMu      sync.Mutex
	trendHistory map[string][]trendSample // last N samples per set

	// Cache file
	cacheDir       string
	cacheDirty     atomic.Bool
	lastCacheWrite time.Time
	daemonPID      int

	// Debounce timer for cache writes
	writeMu sync.Mutex
}

// trendSample records a count at a point in time
type trendSample struct {
	Count     int64
	Timestamp time.Time
}

// SetCountSnapshot is the JSON-serializable snapshot of all counters
type SetCountSnapshot struct {
	Timestamp        string                   `json:"timestamp"`
	DaemonPID        int                      `json:"daemon_pid"`
	ScaleMode        string                   `json:"scale_mode"`
	ExporterInterval int                      `json:"exporter_interval_seconds"`
	Sets             map[string]SetCountEntry `json:"sets"`
}

// SetCountEntry is per-set data in the snapshot
type SetCountEntry struct {
	Count          int64  `json:"count"`
	Scale          string `json:"scale"`
	ScaleNum       int    `json:"scale_num"`
	Display        string `json:"display"`
	LastReconciled string `json:"last_reconciled"`
	Trend          string `json:"trend"`
}

// NewSetCounters creates a new counter tracker
func NewSetCounters(cacheDir string) *SetCounters {
	return &SetCounters{
		counts:       make(map[string]*atomic.Int64),
		lastSync:     make(map[string]time.Time),
		trendHistory: make(map[string][]trendSample),
		cacheDir:     cacheDir,
		daemonPID:    os.Getpid(),
	}
}

// Get returns the current count for a set
func (sc *SetCounters) Get(setName string) int64 {
	sc.mu.RLock()
	counter, ok := sc.counts[setName]
	sc.mu.RUnlock()
	if !ok {
		return 0
	}
	return counter.Load()
}

// Set sets the count for a set to an absolute value
// Used after replace_set, load_cidrs, flush_set, and reconciliation
func (sc *SetCounters) Set(setName string, count int64) {
	sc.mu.Lock()
	counter, ok := sc.counts[setName]
	if !ok {
		counter = &atomic.Int64{}
		sc.counts[setName] = counter
	}
	sc.mu.Unlock()

	counter.Store(count)
	sc.recordTrend(setName, count)
	sc.cacheDirty.Store(true)
}

// Add adjusts the count by delta (positive for adds, negative for deletes)
func (sc *SetCounters) Add(setName string, delta int64) {
	sc.mu.Lock()
	counter, ok := sc.counts[setName]
	if !ok {
		counter = &atomic.Int64{}
		sc.counts[setName] = counter
	}
	sc.mu.Unlock()

	newVal := counter.Add(delta)
	// Guard against negative counts
	if newVal < 0 {
		counter.Store(0)
	}
	sc.cacheDirty.Store(true)
}

// SetReconciled marks when a set was last reconciled against the kernel
func (sc *SetCounters) SetReconciled(setName string, count int64) {
	sc.Set(setName, count)
	sc.mu.Lock()
	sc.lastSync[setName] = time.Now()
	sc.mu.Unlock()
	log.Printf("[set_counters] Reconciled %s: count=%d", setName, count)
}

// Scale returns the scale level for a set
func (sc *SetCounters) Scale(setName string) string {
	count := sc.Get(setName)
	return scaleForCount(count)
}

// ScaleNum returns the numeric scale level for Prometheus
func (sc *SetCounters) ScaleNum(setName string) int {
	count := sc.Get(setName)
	return scaleNumForCount(count)
}

// GlobalScale returns the highest scale level across all sets
func (sc *SetCounters) GlobalScale() string {
	sc.mu.RLock()
	defer sc.mu.RUnlock()

	maxScale := ScaleNormal
	maxNum := ScaleNumNormal

	for name := range sc.counts {
		n := scaleNumForCount(sc.counts[name].Load())
		if n > maxNum {
			maxNum = n
			maxScale = scaleForNum(n)
		}
	}
	_ = maxScale // suppress unused warning
	return scaleForNum(maxNum)
}

// RecommendedExporterInterval returns the recommended exporter interval based on global scale
func (sc *SetCounters) RecommendedExporterInterval() time.Duration {
	scale := sc.GlobalScale()
	switch scale {
	case ScaleNormal:
		return 60 * time.Second
	case ScaleLarge:
		return 60 * time.Second
	case ScaleVeryLarge:
		return 120 * time.Second
	case ScaleHuge:
		return 300 * time.Second
	case ScaleExtreme:
		return 600 * time.Second
	case ScaleCritical:
		return 900 * time.Second
	default:
		return 60 * time.Second
	}
}

// ReconcileInterval returns the recommended reconciliation interval
func (sc *SetCounters) ReconcileInterval() time.Duration {
	scale := sc.GlobalScale()
	switch scale {
	case ScaleNormal:
		return 1 * time.Hour
	case ScaleLarge:
		return 2 * time.Hour
	case ScaleVeryLarge:
		return 4 * time.Hour
	default:
		// HUGE, EXTREME, CRITICAL_SCALE — hard max 6h
		return 6 * time.Hour
	}
}

// Snapshot returns a JSON-serializable snapshot of all counters
func (sc *SetCounters) Snapshot() SetCountSnapshot {
	sc.mu.RLock()
	defer sc.mu.RUnlock()

	sets := make(map[string]SetCountEntry, len(sc.counts))
	for name, counter := range sc.counts {
		count := counter.Load()
		lastReconciled := ""
		if t, ok := sc.lastSync[name]; ok {
			lastReconciled = t.UTC().Format(time.RFC3339)
		}

		sets[name] = SetCountEntry{
			Count:          count,
			Scale:          scaleForCount(count),
			ScaleNum:       scaleNumForCount(count),
			Display:        formatCount(count),
			LastReconciled: lastReconciled,
			Trend:          sc.computeTrend(name),
		}
	}

	interval := sc.RecommendedExporterInterval()

	return SetCountSnapshot{
		Timestamp:        time.Now().UTC().Format(time.RFC3339),
		DaemonPID:        sc.daemonPID,
		ScaleMode:        sc.globalScaleLocked(),
		ExporterInterval: int(interval.Seconds()),
		Sets:             sets,
	}
}

// WriteCacheFile writes the snapshot to /run/nftban/set_counts.json
// Debounced: only writes if dirty and at least 10 seconds since last write
func (sc *SetCounters) WriteCacheFile() error {
	if !sc.cacheDirty.Load() {
		return nil
	}

	sc.writeMu.Lock()
	defer sc.writeMu.Unlock()

	// Debounce: min 10 seconds between writes
	if time.Since(sc.lastCacheWrite) < 10*time.Second {
		return nil
	}

	snap := sc.Snapshot()

	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal set_counts: %w", err)
	}

	cacheFile := filepath.Join(sc.cacheDir, "set_counts.json")

	// v1.176 FSYNC-RESIDUAL (F-1): route through safety.SafeWriteFile — temp +
	// fsync + atomic rename (was os.WriteFile(tmp)+Rename with NO Sync → a crash
	// between rename and writeback could leave a torn/zero-length set_counts.json).
	// 0640: root-rw, group-r — shell scripts read this via nftban group.
	if err := safety.SafeWriteFile(cacheFile, data, 0640); err != nil {
		return fmt.Errorf("write %s: %w", cacheFile, err)
	}

	sc.lastCacheWrite = time.Now()
	sc.cacheDirty.Store(false)
	return nil
}

// CacheWriterLoop runs the background cache file writer
// Writes every 10 seconds if dirty
func (sc *SetCounters) CacheWriterLoop(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			// Final write on shutdown
			if err := sc.WriteCacheFile(); err != nil {
				log.Printf("[set_counters] Final cache write failed: %v", err)
			}
			return
		case <-ticker.C:
			if err := sc.WriteCacheFile(); err != nil {
				log.Printf("[set_counters] Cache write failed: %v", err)
			}
		}
	}
}

// AllSets returns the names of all tracked sets
func (sc *SetCounters) AllSets() []string {
	sc.mu.RLock()
	defer sc.mu.RUnlock()
	names := make([]string, 0, len(sc.counts))
	for name := range sc.counts {
		names = append(names, name)
	}
	return names
}

// recordTrend records a trend sample for the given set
func (sc *SetCounters) recordTrend(setName string, count int64) {
	sc.trendMu.Lock()
	defer sc.trendMu.Unlock()

	samples := sc.trendHistory[setName]
	samples = append(samples, trendSample{Count: count, Timestamp: time.Now()})

	// Keep last 360 samples (1h at 10s intervals)
	if len(samples) > 360 {
		samples = samples[len(samples)-360:]
	}
	sc.trendHistory[setName] = samples
}

// computeTrend returns a human-readable trend string
func (sc *SetCounters) computeTrend(setName string) string {
	sc.trendMu.Lock()
	defer sc.trendMu.Unlock()

	samples := sc.trendHistory[setName]
	if len(samples) < 2 {
		return "no data"
	}

	current := samples[len(samples)-1]

	// Find 1h-ago sample (or earliest)
	var ref trendSample
	oneHourAgo := time.Now().Add(-1 * time.Hour)
	for _, s := range samples {
		if s.Timestamp.Before(oneHourAgo) {
			ref = s
		}
	}
	if ref.Timestamp.IsZero() {
		ref = samples[0]
	}

	delta := current.Count - ref.Count
	elapsed := current.Timestamp.Sub(ref.Timestamp)

	if elapsed < 1*time.Minute {
		return "no data"
	}

	if delta == 0 {
		return "stable"
	}

	// Format the trend
	sign := "+"
	if delta < 0 {
		sign = ""
	}

	if elapsed >= 50*time.Minute {
		return fmt.Sprintf("%s%d in last 1h", sign, delta)
	}
	minutes := int(elapsed.Minutes())
	return fmt.Sprintf("%s%d in last %dm", sign, delta, minutes)
}

// --- Helper functions ---

func scaleForCount(count int64) string {
	switch {
	case count >= ThresholdCritical:
		return ScaleCritical
	case count >= ThresholdExtreme:
		return ScaleExtreme
	case count >= ThresholdHuge:
		return ScaleHuge
	case count >= ThresholdVeryLarge:
		return ScaleVeryLarge
	case count >= ThresholdLarge:
		return ScaleLarge
	default:
		return ScaleNormal
	}
}

func scaleNumForCount(count int64) int {
	switch {
	case count >= ThresholdCritical:
		return ScaleNumCritical
	case count >= ThresholdExtreme:
		return ScaleNumExtreme
	case count >= ThresholdHuge:
		return ScaleNumHuge
	case count >= ThresholdVeryLarge:
		return ScaleNumVeryLarge
	case count >= ThresholdLarge:
		return ScaleNumLarge
	default:
		return ScaleNumNormal
	}
}

func scaleForNum(n int) string {
	switch n {
	case ScaleNumCritical:
		return ScaleCritical
	case ScaleNumExtreme:
		return ScaleExtreme
	case ScaleNumHuge:
		return ScaleHuge
	case ScaleNumVeryLarge:
		return ScaleVeryLarge
	case ScaleNumLarge:
		return ScaleLarge
	default:
		return ScaleNormal
	}
}

// formatCount returns a human-readable count with appropriate rounding
func formatCount(count int64) string {
	switch {
	case count >= 1_000_000:
		// Round to nearest 10K
		rounded := (count + 5000) / 10_000 * 10_000
		return fmt.Sprintf("~%.1fM", float64(rounded)/1_000_000)
	case count >= 250_000:
		// Round to nearest 5K
		rounded := (count + 2500) / 5000 * 5000
		return fmt.Sprintf("~%dK", rounded/1000)
	case count >= 100_000:
		// Round to nearest 1K
		rounded := (count + 500) / 1000 * 1000
		return fmt.Sprintf("~%dK", rounded/1000)
	default:
		// Exact with comma separators
		return formatWithCommas(count)
	}
}

// formatWithCommas formats an integer with comma separators
func formatWithCommas(n int64) string {
	if n < 0 {
		return "-" + formatWithCommas(-n)
	}
	if n < 1000 {
		return fmt.Sprintf("%d", n)
	}
	return formatWithCommas(n/1000) + fmt.Sprintf(",%03d", n%1000)
}

// globalScaleLocked returns global scale (caller must hold mu.RLock)
func (sc *SetCounters) globalScaleLocked() string {
	maxNum := ScaleNumNormal
	for _, counter := range sc.counts {
		n := scaleNumForCount(counter.Load())
		if n > maxNum {
			maxNum = n
		}
	}
	return scaleForNum(maxNum)
}
