// =============================================================================
// NFTBan - Tests for watchdog flight recorder
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_flight_recorder_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for watchdog flight recorder"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
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
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// =============================================================================
// NewRecorder
// =============================================================================

func TestNewRecorder(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderMaxEvents = 500
	r := NewRecorder(cfg)

	if r == nil {
		t.Fatal("NewRecorder() returned nil")
	}
	if len(r.events) != 500 {
		t.Errorf("events buffer len = %d, want 500", len(r.events))
	}
	if r.eventHead != 0 {
		t.Errorf("eventHead = %d, want 0", r.eventHead)
	}
}

// =============================================================================
// RecordEvent - Ring Buffer Behavior
// =============================================================================

func TestRecordEvent_SingleEvent(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false // disable disk writes
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	event := Event{
		Type:      EventModeChange,
		Timestamp: time.Now(),
		Message:   "test event",
	}

	r.RecordEvent(event)

	stats := r.GetStats()
	if stats.EventsInBuffer != 1 {
		t.Errorf("EventsInBuffer = %d, want 1", stats.EventsInBuffer)
	}
}

func TestRecordEvent_RingBufferWraps(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	// Fill buffer completely plus some overflow
	for i := 0; i < 150; i++ {
		event := Event{
			Type:      EventActionTaken,
			Timestamp: time.Now().Add(time.Duration(i) * time.Second),
			Message:   fmt.Sprintf("event %d", i),
		}
		r.RecordEvent(event)
	}

	stats := r.GetStats()
	if stats.EventsInBuffer != 100 {
		t.Errorf("EventsInBuffer = %d, want 100 (buffer size)", stats.EventsInBuffer)
	}

	// eventHead should have wrapped around
	if r.eventHead != 50 { // 150 % 100 = 50
		t.Errorf("eventHead = %d, want 50", r.eventHead)
	}
}

func TestRecordEvent_OverwritesOldest(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	// Write 5 events
	for i := 0; i < 5; i++ {
		event := Event{
			Type:      EventModeChange,
			Timestamp: time.Now().Add(time.Duration(i) * time.Second),
			Message:   fmt.Sprintf("event_%d", i),
		}
		r.RecordEvent(event)
	}

	// Get recent events - should get all 5 in chronological order
	events := r.GetRecentEvents(5)
	if len(events) != 5 {
		t.Fatalf("GetRecentEvents(5) = %d events, want 5", len(events))
	}

	// Check chronological order
	if events[0].Message != "event_0" {
		t.Errorf("first event = %q, want %q", events[0].Message, "event_0")
	}
	if events[4].Message != "event_4" {
		t.Errorf("last event = %q, want %q", events[4].Message, "event_4")
	}
}

// =============================================================================
// GetRecentEvents
// =============================================================================

func TestGetRecentEvents_EmptyBuffer(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	events := r.GetRecentEvents(10)
	if len(events) != 0 {
		t.Errorf("GetRecentEvents on empty = %d, want 0", len(events))
	}
}

func TestGetRecentEvents_RequestMoreThanAvailable(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	for i := 0; i < 3; i++ {
		r.RecordEvent(Event{
			Type:      EventModeChange,
			Timestamp: time.Now().Add(time.Duration(i) * time.Second),
			Message:   fmt.Sprintf("event_%d", i),
		})
	}

	events := r.GetRecentEvents(100)
	if len(events) != 3 {
		t.Errorf("GetRecentEvents(100) = %d events, want 3", len(events))
	}
}

func TestGetRecentEvents_RequestMoreThanBufferSize(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	for i := 0; i < 100; i++ {
		r.RecordEvent(Event{
			Type:      EventActionTaken,
			Timestamp: time.Now().Add(time.Duration(i) * time.Second),
			Message:   fmt.Sprintf("event_%d", i),
		})
	}

	events := r.GetRecentEvents(200)
	if len(events) != 100 {
		t.Errorf("GetRecentEvents(200) = %d events, want 100 (capped)", len(events))
	}
}

func TestGetRecentEvents_ChronologicalOrder(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	base := time.Now()
	for i := 0; i < 10; i++ {
		r.RecordEvent(Event{
			Type:      EventModeChange,
			Timestamp: base.Add(time.Duration(i) * time.Second),
			Message:   fmt.Sprintf("event_%d", i),
		})
	}

	events := r.GetRecentEvents(10)

	for i := 1; i < len(events); i++ {
		if events[i].Timestamp.Before(events[i-1].Timestamp) {
			t.Errorf("events not in chronological order at index %d", i)
		}
	}
}

func TestGetRecentEvents_AfterWrap(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 5
	r := NewRecorder(cfg)

	base := time.Now()
	// Write 8 events into a 5-event buffer
	for i := 0; i < 8; i++ {
		r.RecordEvent(Event{
			Type:      EventActionTaken,
			Timestamp: base.Add(time.Duration(i) * time.Second),
			Message:   fmt.Sprintf("event_%d", i),
		})
	}

	events := r.GetRecentEvents(5)
	if len(events) != 5 {
		t.Fatalf("GetRecentEvents(5) = %d events, want 5", len(events))
	}

	// After wrapping, oldest should be event_3 (0,1,2 were overwritten)
	if events[0].Message != "event_3" {
		t.Errorf("oldest event after wrap = %q, want %q", events[0].Message, "event_3")
	}
	if events[4].Message != "event_7" {
		t.Errorf("newest event after wrap = %q, want %q", events[4].Message, "event_7")
	}
}

// =============================================================================
// RecordModeChange
// =============================================================================

func TestRecordModeChange(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	snapshot := &Snapshot{Process: ProcessMetrics{PID: 1234}}
	r.RecordModeChange(ModeNormal, ModeDegraded, snapshot)

	events := r.GetRecentEvents(1)
	if len(events) != 1 {
		t.Fatalf("want 1 event, got %d", len(events))
	}

	event := events[0]
	if event.Type != EventModeChange {
		t.Errorf("type = %q, want %q", event.Type, EventModeChange)
	}
	if event.OldMode != ModeNormal {
		t.Errorf("OldMode = %q, want %q", event.OldMode, ModeNormal)
	}
	if event.NewMode != ModeDegraded {
		t.Errorf("NewMode = %q, want %q", event.NewMode, ModeDegraded)
	}
	if event.Snapshot == nil {
		t.Error("Snapshot should not be nil")
	}
}

// =============================================================================
// RecordPressureChange
// =============================================================================

func TestRecordPressureChange(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	r.RecordPressureChange(DimCPU, LevelOK, LevelWarn, 65.0)

	events := r.GetRecentEvents(1)
	if len(events) != 1 {
		t.Fatalf("want 1 event, got %d", len(events))
	}

	event := events[0]
	if event.Type != EventPressureChange {
		t.Errorf("type = %q, want %q", event.Type, EventPressureChange)
	}
	if event.Dimension != DimCPU {
		t.Errorf("Dimension = %q, want %q", event.Dimension, DimCPU)
	}
	if event.Level != LevelWarn {
		t.Errorf("Level = %q, want %q", event.Level, LevelWarn)
	}
	if event.Score != 65.0 {
		t.Errorf("Score = %f, want 65.0", event.Score)
	}
}

// =============================================================================
// RecordAction
// =============================================================================

func TestRecordAction(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	action := Action{
		Type:      ActionThrottle,
		Timestamp: time.Now(),
		Reason:    "survival_mode",
		Details:   "workers: 10->5",
		Success:   true,
	}

	r.RecordAction(action, &Snapshot{})

	events := r.GetRecentEvents(1)
	if len(events) != 1 {
		t.Fatalf("want 1 event, got %d", len(events))
	}

	event := events[0]
	if event.Type != EventActionTaken {
		t.Errorf("type = %q, want %q", event.Type, EventActionTaken)
	}
	if event.Action == nil {
		t.Fatal("Action should not be nil")
	}
	if event.Action.Type != ActionThrottle {
		t.Errorf("Action.Type = %q, want %q", event.Action.Type, ActionThrottle)
	}
}

// =============================================================================
// RecordThresholdBreach
// =============================================================================

func TestRecordThresholdBreach(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	r.RecordThresholdBreach(DimMEM, 85.0, 80.0, &Snapshot{})

	events := r.GetRecentEvents(1)
	if len(events) != 1 {
		t.Fatalf("want 1 event, got %d", len(events))
	}

	event := events[0]
	if event.Type != EventThresholdBreach {
		t.Errorf("type = %q, want %q", event.Type, EventThresholdBreach)
	}
	if event.Dimension != DimMEM {
		t.Errorf("Dimension = %q, want %q", event.Dimension, DimMEM)
	}
	if event.Score != 85.0 {
		t.Errorf("Score = %f, want 85.0", event.Score)
	}
}

// =============================================================================
// RecordSnapshot
// =============================================================================

func TestRecordSnapshot_StoresLastSnapshot(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	cfg.RecorderSnapshotInterval = time.Hour // won't write to disk
	r := NewRecorder(cfg)

	snapshot := &Snapshot{
		Timestamp: time.Now(),
		Process:   ProcessMetrics{PID: 42, RSS: 1024},
	}

	r.RecordSnapshot(snapshot)

	if r.lastSnapshot == nil {
		t.Error("lastSnapshot should be set")
	}
	if r.lastSnapshot.Process.PID != 42 {
		t.Errorf("lastSnapshot.Process.PID = %d, want 42", r.lastSnapshot.Process.PID)
	}
}

func TestRecordSnapshot_WritesWhenIntervalPassed(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := testConfig()
	cfg.RecorderEnabled = true
	cfg.RecorderDir = tmpDir
	cfg.RecorderMaxEvents = 100
	cfg.RecorderSnapshotInterval = 0 // always write
	r := NewRecorder(cfg)

	snapshot := &Snapshot{
		Timestamp: time.Now(),
		Process:   ProcessMetrics{PID: 42},
		NFTables:  NFTablesMetrics{SetElements: map[string]int{}},
	}

	r.RecordSnapshot(snapshot)

	// Check that snapshot directory was created
	snapshotDir := filepath.Join(tmpDir, "snapshots")
	entries, err := os.ReadDir(snapshotDir)
	if err != nil {
		t.Fatalf("ReadDir(%s) error = %v", snapshotDir, err)
	}
	if len(entries) == 0 {
		t.Error("expected at least one snapshot file")
	}
}

// =============================================================================
// Flush
// =============================================================================

func TestFlush_WithSnapshot(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := testConfig()
	cfg.RecorderEnabled = true
	cfg.RecorderDir = tmpDir
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	// Record an event
	r.RecordEvent(Event{
		Type:      EventModeChange,
		Timestamp: time.Now(),
		Message:   "test",
	})

	// Set last snapshot
	r.mu.Lock()
	r.lastSnapshot = &Snapshot{
		Timestamp: time.Now(),
		NFTables:  NFTablesMetrics{SetElements: map[string]int{}},
	}
	r.mu.Unlock()

	err := r.Flush()
	if err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
}

func TestFlush_EmptyRecorder(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := testConfig()
	cfg.RecorderEnabled = true
	cfg.RecorderDir = tmpDir
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	err := r.Flush()
	if err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
}

func TestFlush_DisabledRecorder(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	r.RecordEvent(Event{
		Type:      EventModeChange,
		Timestamp: time.Now(),
		Message:   "test",
	})

	err := r.Flush()
	if err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
}

// =============================================================================
// GetStats
// =============================================================================

func TestGetStats_Empty(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderMaxEvents = 200
	r := NewRecorder(cfg)

	stats := r.GetStats()
	if stats.EventsInBuffer != 0 {
		t.Errorf("EventsInBuffer = %d, want 0", stats.EventsInBuffer)
	}
	if stats.MaxEvents != 200 {
		t.Errorf("MaxEvents = %d, want 200", stats.MaxEvents)
	}
	if !stats.LastEventWrite.IsZero() {
		t.Error("LastEventWrite should be zero")
	}
	if !stats.LastSnapshotWrite.IsZero() {
		t.Error("LastSnapshotWrite should be zero")
	}
}

func TestGetStats_WithEvents(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	for i := 0; i < 5; i++ {
		r.RecordEvent(Event{
			Type:      EventActionTaken,
			Timestamp: time.Now(),
			Message:   fmt.Sprintf("event_%d", i),
		})
	}

	stats := r.GetStats()
	if stats.EventsInBuffer != 5 {
		t.Errorf("EventsInBuffer = %d, want 5", stats.EventsInBuffer)
	}
}

func TestGetStats_FullBuffer(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	for i := 0; i < 150; i++ {
		r.RecordEvent(Event{
			Type:      EventActionTaken,
			Timestamp: time.Now().Add(time.Duration(i) * time.Second),
			Message:   fmt.Sprintf("event_%d", i),
		})
	}

	stats := r.GetStats()
	if stats.EventsInBuffer != 100 {
		t.Errorf("EventsInBuffer = %d, want 100 (full buffer)", stats.EventsInBuffer)
	}
}

// =============================================================================
// Cleanup
// =============================================================================

func TestCleanup_RemovesOldFiles(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := testConfig()
	cfg.RecorderEnabled = true
	cfg.RecorderDir = tmpDir
	cfg.RecorderRetentionDays = 1
	cfg.ProfileDir = filepath.Join(tmpDir, "profiles")
	cfg.ProfileMaxCount = 2
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	// Create old event file
	eventDir := filepath.Join(tmpDir, "events")
	os.MkdirAll(eventDir, 0750)
	oldFile := filepath.Join(eventDir, "events_old.jsonl")
	os.WriteFile(oldFile, []byte("test"), 0640)

	// Set modification time to 30 days ago
	oldTime := time.Now().AddDate(0, 0, -30)
	os.Chtimes(oldFile, oldTime, oldTime)

	// Create recent event file
	recentFile := filepath.Join(eventDir, "events_recent.jsonl")
	os.WriteFile(recentFile, []byte("test"), 0640)

	err := r.Cleanup()
	if err != nil {
		t.Fatalf("Cleanup() error = %v", err)
	}

	// Old file should be removed
	if _, err := os.Stat(oldFile); !os.IsNotExist(err) {
		t.Error("old file should have been removed")
	}

	// Recent file should still exist
	if _, err := os.Stat(recentFile); err != nil {
		t.Error("recent file should still exist")
	}
}

func TestCleanup_ProfileCountLimit(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := testConfig()
	cfg.RecorderEnabled = true
	cfg.RecorderDir = filepath.Join(tmpDir, "recorder")
	cfg.ProfileDir = filepath.Join(tmpDir, "profiles")
	cfg.ProfileMaxCount = 2
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	// Create profile dir and files
	os.MkdirAll(cfg.ProfileDir, 0750)
	for i := 0; i < 5; i++ {
		name := fmt.Sprintf("cpu_%d.pprof", i)
		path := filepath.Join(cfg.ProfileDir, name)
		os.WriteFile(path, []byte("profile"), 0640)
		// Stagger modification times
		modTime := time.Now().Add(time.Duration(i) * time.Minute)
		os.Chtimes(path, modTime, modTime)

		// Also create sidecar
		os.WriteFile(path+".json", []byte("{}"), 0640)
	}

	r.Cleanup()

	// Should keep only ProfileMaxCount profiles
	entries, _ := os.ReadDir(cfg.ProfileDir)
	pprofCount := 0
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".pprof" {
			pprofCount++
		}
	}

	if pprofCount != 2 {
		t.Errorf("profiles remaining = %d, want 2 (ProfileMaxCount)", pprofCount)
	}
}

// =============================================================================
// Concurrency
// =============================================================================

func TestRecorderConcurrency(t *testing.T) {
	cfg := testConfig()
	cfg.RecorderEnabled = false
	cfg.RecorderMaxEvents = 100
	r := NewRecorder(cfg)

	var wg sync.WaitGroup

	// Writers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				r.RecordEvent(Event{
					Type:      EventActionTaken,
					Timestamp: time.Now(),
					Message:   fmt.Sprintf("g%d_e%d", n, j),
				})
			}
		}(i)
	}

	// Mode change recorder
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r.RecordModeChange(ModeNormal, ModeDegraded, &Snapshot{})
		}()
	}

	// Readers
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = r.GetRecentEvents(10)
			_ = r.GetStats()
		}()
	}

	wg.Wait()
}
