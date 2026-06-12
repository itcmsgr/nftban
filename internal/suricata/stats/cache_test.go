// =============================================================================
// NFTBan v1.0 - Suricata SID Statistics Cache Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cache_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for SID stats cache: recording, eviction, retrieval"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package stats

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestMigrateLegacySnapshot locks the v1.175 FHS-SMELL-SIDSTATS relocation:
// the SID-stats snapshot moved from /etc (ConfigDir) to /var/lib (DataDir), and
// migrateLegacySnapshot moves a pre-v1.175 file on first startup. Best-effort:
// failures must never panic; Load() just starts fresh.
func TestMigrateLegacySnapshot(t *testing.T) {
	t.Run("moves legacy file and removes old", func(t *testing.T) {
		dir := t.TempDir()
		oldPath := filepath.Join(dir, "etc/suricata/cache/sid-stats.json")
		newPath := filepath.Join(dir, "var/suricata/cache/sid-stats.json")
		if err := os.MkdirAll(filepath.Dir(oldPath), 0750); err != nil {
			t.Fatal(err)
		}
		want := []byte(`[{"sid":"1","trigger_count":7}]`)
		if err := os.WriteFile(oldPath, want, 0644); err != nil {
			t.Fatal(err)
		}

		migrateLegacySnapshot(oldPath, newPath)

		got, err := os.ReadFile(newPath)
		if err != nil {
			t.Fatalf("new snapshot not created: %v", err)
		}
		if string(got) != string(want) {
			t.Errorf("content not preserved: got %q want %q", got, want)
		}
		if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
			t.Errorf("old snapshot should be removed after migration, stat err=%v", err)
		}
	})

	t.Run("no-op when new already exists", func(t *testing.T) {
		dir := t.TempDir()
		oldPath := filepath.Join(dir, "etc/sid-stats.json")
		newPath := filepath.Join(dir, "var/sid-stats.json")
		_ = os.MkdirAll(filepath.Dir(oldPath), 0750)
		_ = os.MkdirAll(filepath.Dir(newPath), 0750)
		if err := os.WriteFile(oldPath, []byte("OLD"), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(newPath, []byte("NEW"), 0644); err != nil {
			t.Fatal(err)
		}

		migrateLegacySnapshot(oldPath, newPath)

		// New must be untouched; old must remain (we never overwrite/clobber).
		if got, _ := os.ReadFile(newPath); string(got) != "NEW" {
			t.Errorf("existing new snapshot was overwritten: got %q", got)
		}
		if _, err := os.Stat(oldPath); err != nil {
			t.Errorf("old snapshot should be left intact when new exists, err=%v", err)
		}
	})

	t.Run("no-op when neither exists", func(t *testing.T) {
		dir := t.TempDir()
		newPath := filepath.Join(dir, "var/sid-stats.json")
		// Must not panic and must not create anything.
		migrateLegacySnapshot(filepath.Join(dir, "etc/sid-stats.json"), newPath)
		if _, err := os.Stat(newPath); !os.IsNotExist(err) {
			t.Errorf("nothing should be created when neither file exists")
		}
	})
}

// newTestCache creates a Cache without calling nftbanconf.MustLoad() or
// safety.GetMemoryLimits() so tests can run without production config files.
func newTestCache(maxSIDs, maxSourcesPerSID int) *Cache {
	return &Cache{
		stats:            make(map[string]*SIDStats),
		snapshotPath:     "/tmp/nftban-test-sid-stats.json",
		maxSIDs:          maxSIDs,
		maxSourcesPerSID: maxSourcesPerSID,
	}
}

// =============================================================================
// RecordTrigger Tests
// =============================================================================

func TestRecordTrigger_NewSID(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("2100001", "exploit", "ET EXPLOIT Test", "1.2.3.4", now)

	stats, ok := c.GetSIDStats("2100001")
	if !ok {
		t.Fatal("expected SID to be tracked")
	}
	if stats.SID != "2100001" {
		t.Errorf("expected SID %q, got %q", "2100001", stats.SID)
	}
	if stats.Category != "exploit" {
		t.Errorf("expected category %q, got %q", "exploit", stats.Category)
	}
	if stats.Signature != "ET EXPLOIT Test" {
		t.Errorf("expected signature %q, got %q", "ET EXPLOIT Test", stats.Signature)
	}
	if stats.TriggerCount != 1 {
		t.Errorf("expected TriggerCount=1, got %d", stats.TriggerCount)
	}
	if stats.SourceCount != 1 {
		t.Errorf("expected SourceCount=1, got %d", stats.SourceCount)
	}
}

func TestRecordTrigger_ExistingSID(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("2100001", "exploit", "ET EXPLOIT Test", "1.2.3.4", now)
	c.RecordTrigger("2100001", "exploit", "ET EXPLOIT Test", "1.2.3.4", now.Add(1*time.Second))
	c.RecordTrigger("2100001", "exploit", "ET EXPLOIT Test", "5.6.7.8", now.Add(2*time.Second))

	stats, ok := c.GetSIDStats("2100001")
	if !ok {
		t.Fatal("expected SID to be tracked")
	}
	if stats.TriggerCount != 3 {
		t.Errorf("expected TriggerCount=3, got %d", stats.TriggerCount)
	}
	if stats.SourceCount != 2 {
		t.Errorf("expected SourceCount=2 (unique sources), got %d", stats.SourceCount)
	}
}

func TestRecordTrigger_EmptySourceIP(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("2100001", "exploit", "ET EXPLOIT Test", "", now)

	stats, ok := c.GetSIDStats("2100001")
	if !ok {
		t.Fatal("expected SID to be tracked")
	}
	if stats.TriggerCount != 1 {
		t.Errorf("expected TriggerCount=1, got %d", stats.TriggerCount)
	}
	if stats.SourceCount != 0 {
		t.Errorf("expected SourceCount=0 (empty IP), got %d", stats.SourceCount)
	}
}

func TestRecordTrigger_UpdatesTimestamps(t *testing.T) {
	c := newTestCache(1000, 100)
	first := time.Now().Add(-5 * time.Minute)
	second := time.Now()

	c.RecordTrigger("2100001", "exploit", "ET EXPLOIT Test", "1.2.3.4", first)
	c.RecordTrigger("2100001", "exploit", "ET EXPLOIT Test", "1.2.3.4", second)

	stats, ok := c.GetSIDStats("2100001")
	if !ok {
		t.Fatal("expected SID to be tracked")
	}
	if !stats.FirstTrigger.Equal(first) {
		t.Errorf("expected FirstTrigger=%v, got %v", first, stats.FirstTrigger)
	}
	if !stats.LastTrigger.Equal(second) {
		t.Errorf("expected LastTrigger=%v, got %v", second, stats.LastTrigger)
	}
}

// =============================================================================
// SID Capacity Eviction Tests
// =============================================================================

func TestRecordTrigger_SIDEviction(t *testing.T) {
	c := newTestCache(3, 100) // Max 3 SIDs

	now := time.Now()
	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now.Add(-3*time.Minute))
	c.RecordTrigger("sid2", "cat2", "sig2", "2.2.2.2", now.Add(-2*time.Minute))
	c.RecordTrigger("sid3", "cat3", "sig3", "3.3.3.3", now.Add(-1*time.Minute))

	if c.GetSize() != 3 {
		t.Errorf("expected 3 SIDs, got %d", c.GetSize())
	}

	// Adding 4th SID should evict the oldest (sid1)
	c.RecordTrigger("sid4", "cat4", "sig4", "4.4.4.4", now)

	if c.GetSize() != 3 {
		t.Errorf("expected 3 SIDs after eviction, got %d", c.GetSize())
	}

	// sid1 (oldest) should be gone
	_, ok := c.GetSIDStats("sid1")
	if ok {
		t.Error("expected sid1 to be evicted")
	}

	// sid4 should exist
	_, ok = c.GetSIDStats("sid4")
	if !ok {
		t.Error("expected sid4 to exist")
	}
}

// =============================================================================
// Source IP Cap Tests
// =============================================================================

func TestRecordTrigger_SourceIPCap(t *testing.T) {
	c := newTestCache(1000, 3) // Max 3 sources per SID

	now := time.Now()
	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid1", "cat1", "sig1", "2.2.2.2", now)
	c.RecordTrigger("sid1", "cat1", "sig1", "3.3.3.3", now)
	// 4th unique source should be ignored (at cap)
	c.RecordTrigger("sid1", "cat1", "sig1", "4.4.4.4", now)

	stats, _ := c.GetSIDStats("sid1")
	if stats.SourceCount != 3 {
		t.Errorf("expected SourceCount=3 (capped), got %d", stats.SourceCount)
	}
	if stats.TriggerCount != 4 {
		t.Errorf("expected TriggerCount=4, got %d", stats.TriggerCount)
	}
}

// =============================================================================
// GetTopSIDs Tests
// =============================================================================

func TestGetTopSIDs(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	// sid1 = 5 triggers, sid2 = 10 triggers, sid3 = 1 trigger
	for i := 0; i < 5; i++ {
		c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	}
	for i := 0; i < 10; i++ {
		c.RecordTrigger("sid2", "cat2", "sig2", "2.2.2.2", now)
	}
	c.RecordTrigger("sid3", "cat3", "sig3", "3.3.3.3", now)

	top := c.GetTopSIDs(2)
	if len(top) != 2 {
		t.Fatalf("expected 2 top SIDs, got %d", len(top))
	}

	// First should be sid2 (most triggers)
	if top[0].SID != "sid2" {
		t.Errorf("expected top[0]=sid2, got %s", top[0].SID)
	}
	if top[0].TriggerCount != 10 {
		t.Errorf("expected top[0].TriggerCount=10, got %d", top[0].TriggerCount)
	}

	// Second should be sid1
	if top[1].SID != "sid1" {
		t.Errorf("expected top[1]=sid1, got %s", top[1].SID)
	}
}

func TestGetTopSIDs_AllItems(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid2", "cat2", "sig2", "2.2.2.2", now)

	// Request more than available
	top := c.GetTopSIDs(10)
	if len(top) != 2 {
		t.Errorf("expected 2 SIDs (all available), got %d", len(top))
	}

	// Request all with -1
	all := c.GetTopSIDs(-1)
	if len(all) != 2 {
		t.Errorf("expected 2 SIDs with -1, got %d", len(all))
	}
}

// =============================================================================
// GetRecentSIDs Tests
// =============================================================================

func TestGetRecentSIDs(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	// Recent SID
	c.RecordTrigger("recent", "cat1", "sig1", "1.1.1.1", now)

	// Old SID (manually set)
	c.mu.Lock()
	c.stats["old"] = &SIDStats{
		SID:           "old",
		Category:      "cat2",
		Signature:     "sig2",
		TriggerCount:  1,
		LastTrigger:   now.Add(-2 * time.Hour),
		FirstTrigger:  now.Add(-2 * time.Hour),
		UniqueSources: map[string]bool{"2.2.2.2": true},
		SourceCount:   1,
	}
	c.mu.Unlock()

	recent := c.GetRecentSIDs(1 * time.Hour)
	if len(recent) != 1 {
		t.Fatalf("expected 1 recent SID, got %d", len(recent))
	}
	if recent[0].SID != "recent" {
		t.Errorf("expected recent SID, got %s", recent[0].SID)
	}
}

// =============================================================================
// GetSize / GetTotalTriggers / GetUniqueSources Tests
// =============================================================================

func TestGetSize(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	if c.GetSize() != 0 {
		t.Errorf("expected size 0, got %d", c.GetSize())
	}

	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid2", "cat2", "sig2", "2.2.2.2", now)

	if c.GetSize() != 2 {
		t.Errorf("expected size 2, got %d", c.GetSize())
	}
}

func TestGetUniqueSIDs(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid1", "cat1", "sig1", "2.2.2.2", now) // Same SID

	if c.GetUniqueSIDs() != 1 {
		t.Errorf("expected 1 unique SID, got %d", c.GetUniqueSIDs())
	}
}

func TestGetTotalTriggers(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid1", "cat1", "sig1", "2.2.2.2", now)
	c.RecordTrigger("sid2", "cat2", "sig2", "3.3.3.3", now)

	total := c.GetTotalTriggers()
	if total != 3 {
		t.Errorf("expected 3 total triggers, got %d", total)
	}
}

func TestGetUniqueSources(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid1", "cat1", "sig1", "2.2.2.2", now)
	c.RecordTrigger("sid2", "cat2", "sig2", "1.1.1.1", now) // Same source IP
	c.RecordTrigger("sid2", "cat2", "sig2", "3.3.3.3", now)

	sources := c.GetUniqueSources()
	if sources != 3 {
		t.Errorf("expected 3 unique sources, got %d", sources)
	}
}

// =============================================================================
// Clear Tests
// =============================================================================

func TestClear(t *testing.T) {
	c := newTestCache(1000, 100)
	now := time.Now()

	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid2", "cat2", "sig2", "2.2.2.2", now)

	c.Clear()

	if c.GetSize() != 0 {
		t.Errorf("expected size 0 after Clear, got %d", c.GetSize())
	}
	if c.GetTotalTriggers() != 0 {
		t.Errorf("expected 0 triggers after Clear, got %d", c.GetTotalTriggers())
	}
}

// =============================================================================
// GetStats Tests
// =============================================================================

func TestCacheGetStats(t *testing.T) {
	c := newTestCache(500, 50)
	now := time.Now()

	c.RecordTrigger("sid1", "cat1", "sig1", "1.1.1.1", now)
	c.RecordTrigger("sid1", "cat1", "sig1", "2.2.2.2", now)

	stats := c.GetStats()
	if stats["sids"] != 1 {
		t.Errorf("expected sids=1, got %d", stats["sids"])
	}
	if stats["max_sids"] != 500 {
		t.Errorf("expected max_sids=500, got %d", stats["max_sids"])
	}
	if stats["total_sources"] != 2 {
		t.Errorf("expected total_sources=2, got %d", stats["total_sources"])
	}
	if stats["max_sources_per_sid"] != 50 {
		t.Errorf("expected max_sources_per_sid=50, got %d", stats["max_sources_per_sid"])
	}
}

// =============================================================================
// getTopSourceIPs Tests
// =============================================================================

func TestGetTopSourceIPs(t *testing.T) {
	c := newTestCache(1000, 100)

	sources := map[string]bool{
		"3.3.3.3": true,
		"1.1.1.1": true,
		"2.2.2.2": true,
	}

	ips := c.getTopSourceIPs(sources, 10)
	if len(ips) != 3 {
		t.Errorf("expected 3 IPs, got %d", len(ips))
	}

	// Should be sorted alphabetically
	if ips[0] != "1.1.1.1" {
		t.Errorf("expected first IP %q, got %q", "1.1.1.1", ips[0])
	}
}

func TestGetTopSourceIPs_Limit(t *testing.T) {
	c := newTestCache(1000, 100)

	sources := map[string]bool{
		"1.1.1.1": true,
		"2.2.2.2": true,
		"3.3.3.3": true,
		"4.4.4.4": true,
		"5.5.5.5": true,
	}

	ips := c.getTopSourceIPs(sources, 3)
	if len(ips) != 3 {
		t.Errorf("expected 3 IPs (limited), got %d", len(ips))
	}
}

func TestGetTopSourceIPs_Empty(t *testing.T) {
	c := newTestCache(1000, 100)

	ips := c.getTopSourceIPs(map[string]bool{}, 10)
	if len(ips) != 0 {
		t.Errorf("expected 0 IPs for empty sources, got %d", len(ips))
	}
}
