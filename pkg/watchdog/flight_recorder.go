// =============================================================================
// NFTBan v1.0 - Flight Recorder
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="flight_recorder"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Flight recorder for post-mortem analysis with ring buffer and disk snapshots"
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
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Recorder maintains a flight recorder for watchdog events
type Recorder struct {
	config *Config

	mu sync.Mutex

	// Ring buffer of recent events
	events    []Event
	eventHead int // Next write position

	// Last snapshot for comparison
	lastSnapshot *Snapshot

	// Last write times
	lastEventWrite    time.Time
	lastSnapshotWrite time.Time
}

// NewRecorder creates a new flight recorder
func NewRecorder(cfg *Config) *Recorder {
	return &Recorder{
		config: cfg,
		events: make([]Event, cfg.RecorderMaxEvents),
	}
}

// RecordEvent adds an event to the ring buffer
func (r *Recorder) RecordEvent(event Event) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.events[r.eventHead] = event
	r.eventHead = (r.eventHead + 1) % len(r.events)

	// Periodically flush to disk
	if time.Since(r.lastEventWrite) > time.Minute {
		r.flushEventsLocked()
	}
}

// RecordModeChange records a mode transition event
func (r *Recorder) RecordModeChange(oldMode, newMode Mode, snapshot *Snapshot) {
	event := Event{
		Type:      EventModeChange,
		Timestamp: time.Now(),
		Message:   fmt.Sprintf("mode transition: %s -> %s", oldMode, newMode),
		Snapshot:  snapshot,
		OldMode:   oldMode,
		NewMode:   newMode,
	}
	r.RecordEvent(event)
}

// RecordPressureChange records a pressure level change
func (r *Recorder) RecordPressureChange(dim Dimension, oldLevel, newLevel Level, score float64) {
	event := Event{
		Type:      EventPressureChange,
		Timestamp: time.Now(),
		Message:   fmt.Sprintf("%s pressure: %s -> %s (score=%.1f)", dim, oldLevel, newLevel, score),
		Dimension: dim,
		Score:     score,
		Level:     newLevel,
	}
	r.RecordEvent(event)
}

// RecordAction records an action taken
func (r *Recorder) RecordAction(action Action, snapshot *Snapshot) {
	event := Event{
		Type:      EventActionTaken,
		Timestamp: action.Timestamp,
		Message:   fmt.Sprintf("action: %s - %s", action.Type, action.Reason),
		Snapshot:  snapshot,
		Action:    &action,
	}
	r.RecordEvent(event)
}

// RecordThresholdBreach records a threshold breach
func (r *Recorder) RecordThresholdBreach(dim Dimension, score float64, threshold float64, snapshot *Snapshot) {
	event := Event{
		Type:      EventThresholdBreach,
		Timestamp: time.Now(),
		Message:   fmt.Sprintf("%s threshold breached: %.1f >= %.1f", dim, score, threshold),
		Snapshot:  snapshot,
		Dimension: dim,
		Score:     score,
	}
	r.RecordEvent(event)
}

// RecordSnapshot records a periodic snapshot
func (r *Recorder) RecordSnapshot(snapshot *Snapshot) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.lastSnapshot = snapshot

	// Check if it's time to write
	if time.Since(r.lastSnapshotWrite) >= r.config.RecorderSnapshotInterval {
		r.writeSnapshotLocked(snapshot)
	}
}

// GetRecentEvents returns recent events from the ring buffer
func (r *Recorder) GetRecentEvents(count int) []Event {
	r.mu.Lock()
	defer r.mu.Unlock()

	if count > len(r.events) {
		count = len(r.events)
	}

	result := make([]Event, 0, count)

	// Read backwards from head
	pos := (r.eventHead - 1 + len(r.events)) % len(r.events)
	for i := 0; i < count; i++ {
		if r.events[pos].Timestamp.IsZero() {
			break // Empty slot
		}
		result = append(result, r.events[pos])
		pos = (pos - 1 + len(r.events)) % len(r.events)
	}

	// Reverse to chronological order
	for i, j := 0, len(result)-1; i < j; i, j = i+1, j-1 {
		result[i], result[j] = result[j], result[i]
	}

	return result
}

// Flush writes all pending data to disk
func (r *Recorder) Flush() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if err := r.flushEventsLocked(); err != nil {
		return err
	}

	if r.lastSnapshot != nil {
		if err := r.writeSnapshotLocked(r.lastSnapshot); err != nil {
			return err
		}
	}

	return nil
}

// Cleanup removes old files beyond retention period
func (r *Recorder) Cleanup() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	cutoff := time.Now().AddDate(0, 0, -r.config.RecorderRetentionDays)

	// Clean up event logs
	eventDir := filepath.Join(r.config.RecorderDir, "events")
	r.cleanupOldFiles(eventDir, cutoff)

	// Clean up snapshots
	snapshotDir := filepath.Join(r.config.RecorderDir, "snapshots")
	r.cleanupOldFiles(snapshotDir, cutoff)

	// Clean up profiles (separate limit)
	r.cleanupProfiles()

	return nil
}

// flushEventsLocked writes recent events to disk
func (r *Recorder) flushEventsLocked() error {
	if !r.config.RecorderEnabled {
		return nil
	}

	eventDir := filepath.Join(r.config.RecorderDir, "events")
	if err := os.MkdirAll(eventDir, 0750); err != nil {
		return err
	}

	filename := fmt.Sprintf("events_%s.jsonl", time.Now().Format("2006-01-02"))
	path := filepath.Join(eventDir, filename)

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
	if err != nil {
		return err
	}
	defer f.Close()

	encoder := json.NewEncoder(f)

	// Write all non-empty events since last write
	for i := 0; i < len(r.events); i++ {
		event := r.events[i]
		if event.Timestamp.IsZero() {
			continue
		}
		if event.Timestamp.After(r.lastEventWrite) {
			if err := encoder.Encode(event); err != nil {
				return err
			}
		}
	}

	r.lastEventWrite = time.Now()
	return nil
}

// writeSnapshotLocked writes a snapshot to disk
func (r *Recorder) writeSnapshotLocked(snapshot *Snapshot) error {
	if !r.config.RecorderEnabled {
		return nil
	}

	snapshotDir := filepath.Join(r.config.RecorderDir, "snapshots")
	if err := os.MkdirAll(snapshotDir, 0750); err != nil {
		return err
	}

	filename := fmt.Sprintf("snapshot_%s.json", time.Now().Format("2006-01-02_150405"))
	path := filepath.Join(snapshotDir, filename)

	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return err
	}

	if err := os.WriteFile(path, data, 0640); err != nil {
		return err
	}

	r.lastSnapshotWrite = time.Now()
	return nil
}

// cleanupOldFiles removes files older than cutoff
func (r *Recorder) cleanupOldFiles(dir string, cutoff time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		if info.ModTime().Before(cutoff) {
			os.Remove(filepath.Join(dir, entry.Name()))
		}
	}
}

// cleanupProfiles enforces profile count limit
func (r *Recorder) cleanupProfiles() {
	profileDir := r.config.ProfileDir

	entries, err := os.ReadDir(profileDir)
	if err != nil {
		return
	}

	// Filter to .pprof files
	var profiles []os.DirEntry
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if filepath.Ext(entry.Name()) == ".pprof" {
			profiles = append(profiles, entry)
		}
	}

	if len(profiles) <= r.config.ProfileMaxCount {
		return
	}

	// Sort by modification time (oldest first)
	sort.Slice(profiles, func(i, j int) bool {
		infoI, _ := profiles[i].Info()
		infoJ, _ := profiles[j].Info()
		return infoI.ModTime().Before(infoJ.ModTime())
	})

	// Remove oldest until we're at limit
	toRemove := len(profiles) - r.config.ProfileMaxCount
	for i := 0; i < toRemove; i++ {
		path := filepath.Join(profileDir, profiles[i].Name())
		os.Remove(path)
		// Also remove sidecar
		os.Remove(path + ".json")
	}
}

// GetStats returns recorder statistics
func (r *Recorder) GetStats() RecorderStats {
	r.mu.Lock()
	defer r.mu.Unlock()

	eventCount := 0
	for _, e := range r.events {
		if !e.Timestamp.IsZero() {
			eventCount++
		}
	}

	return RecorderStats{
		EventsInBuffer:    eventCount,
		MaxEvents:         len(r.events),
		LastEventWrite:    r.lastEventWrite,
		LastSnapshotWrite: r.lastSnapshotWrite,
	}
}

// RecorderStats contains recorder statistics
type RecorderStats struct {
	EventsInBuffer    int       `json:"events_in_buffer"`
	MaxEvents         int       `json:"max_events"`
	LastEventWrite    time.Time `json:"last_event_write"`
	LastSnapshotWrite time.Time `json:"last_snapshot_write"`
}
