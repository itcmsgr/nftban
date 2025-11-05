package safety

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPreflightHappyPath(t *testing.T) {
	// Create temp cache dir
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  1000,
		MaxProjectedBytes: 1024 * 1024, // 1 MB
		MaxPctOfAvail:     50,
		MaxAddsPerRun:     500,
		MaxDelsPerRun:     500,
		Enforce:           true,
		CacheDir:          tmpDir,
	}

	// First run (no previous snapshot)
	err := Preflight(100, 50, "hash123", lim)
	if err != nil {
		t.Fatalf("Expected preflight to pass, got error: %v", err)
	}

	// Save snapshot
	snap := Snapshot{TotalV4: 100, TotalV6: 50, Hash: "hash123"}
	if err := SaveSnapshot(tmpDir, snap); err != nil {
		t.Fatalf("Failed to save snapshot: %v", err)
	}

	// Second run with small delta (should pass)
	err = Preflight(150, 60, "hash456", lim)
	if err != nil {
		t.Fatalf("Expected preflight to pass with small delta, got error: %v", err)
	}
}

func TestPreflightAbsoluteCap(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  1000,
		MaxProjectedBytes: 1024 * 1024,
		MaxPctOfAvail:     50,
		MaxAddsPerRun:     10000,
		MaxDelsPerRun:     10000,
		Enforce:           true,
		CacheDir:          tmpDir,
	}

	// Try to load 2000 prefixes (exceeds 1000 cap)
	err := Preflight(2000, 0, "hash", lim)
	if err == nil {
		t.Fatal("Expected preflight to fail due to absolute cap, but passed")
	}
}

func TestPreflightDeltaCap(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  10000,
		MaxProjectedBytes: 10 * 1024 * 1024,
		MaxPctOfAvail:     50,
		MaxAddsPerRun:     100, // Only allow +100
		MaxDelsPerRun:     1000,
		Enforce:           true,
		CacheDir:          tmpDir,
	}

	// Save initial snapshot
	snap := Snapshot{TotalV4: 500, TotalV6: 0, Hash: "hash1"}
	if err := SaveSnapshot(tmpDir, snap); err != nil {
		t.Fatalf("Failed to save snapshot: %v", err)
	}

	// Try to add 500 prefixes (exceeds +100 delta cap)
	err := Preflight(1000, 0, "hash2", lim)
	if err == nil {
		t.Fatal("Expected preflight to fail due to delta cap, but passed")
	}
}

func TestPreflightMemoryCap(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  1000000,
		MaxProjectedBytes: 1024, // Only 1KB allowed
		MaxPctOfAvail:     50,
		MaxAddsPerRun:     1000000,
		MaxDelsPerRun:     1000000,
		Enforce:           true,
		CacheDir:          tmpDir,
	}

	// Try to load 1000 prefixes (~128KB)
	err := Preflight(1000, 0, "hash", lim)
	if err == nil {
		t.Fatal("Expected preflight to fail due to memory cap, but passed")
	}
}

func TestPreflightWarnOnly(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  100,
		MaxProjectedBytes: 1024,
		MaxPctOfAvail:     1,
		MaxAddsPerRun:     10,
		MaxDelsPerRun:     10,
		Enforce:           false, // Warn only, don't block
		CacheDir:          tmpDir,
	}

	// Try to load way over limits (should warn but not error)
	err := Preflight(10000, 5000, "hash", lim)
	if err != nil {
		t.Fatalf("Expected preflight to warn but not error, got: %v", err)
	}
}

func TestSnapshotPersistence(t *testing.T) {
	tmpDir := t.TempDir()

	snap := Snapshot{
		TotalV4: 12345,
		TotalV6: 6789,
		Hash:    "abc123def456",
	}

	// Save
	if err := SaveSnapshot(tmpDir, snap); err != nil {
		t.Fatalf("Failed to save snapshot: %v", err)
	}

	// Load
	loaded, err := LoadSnapshot(tmpDir)
	if err != nil {
		t.Fatalf("Failed to load snapshot: %v", err)
	}

	// Verify
	if loaded.TotalV4 != snap.TotalV4 {
		t.Errorf("TotalV4 mismatch: expected %d, got %d", snap.TotalV4, loaded.TotalV4)
	}
	if loaded.TotalV6 != snap.TotalV6 {
		t.Errorf("TotalV6 mismatch: expected %d, got %d", snap.TotalV6, loaded.TotalV6)
	}
	if loaded.Hash != snap.Hash {
		t.Errorf("Hash mismatch: expected %s, got %s", snap.Hash, loaded.Hash)
	}
}

func TestLoadSnapshotMissing(t *testing.T) {
	tmpDir := t.TempDir()

	// Try to load non-existent snapshot
	_, err := LoadSnapshot(tmpDir)
	if err == nil {
		t.Fatal("Expected error when loading missing snapshot")
	}
}

func TestProjectBytes(t *testing.T) {
	proj := ProjectBytes(1000, 500)

	expectedV4 := int64(1000 * 128)
	expectedV6 := int64(500 * 160)
	expectedTotal := expectedV4 + expectedV6

	if proj.Bytes != expectedTotal {
		t.Errorf("Projected bytes: expected %d, got %d", expectedTotal, proj.Bytes)
	}
	if proj.ElemsV4 != 1000 {
		t.Errorf("ElemsV4: expected 1000, got %d", proj.ElemsV4)
	}
	if proj.ElemsV6 != 500 {
		t.Errorf("ElemsV6: expected 500, got %d", proj.ElemsV6)
	}
}

func TestConfigFromEnv(t *testing.T) {
	// Set test env vars
	os.Setenv("NFTBAN_MAX_PREFIXES", "500000")
	os.Setenv("NFTBAN_MAX_ADDS_PER_RUN", "5000")
	os.Setenv("NFTBAN_GOMAXPROCS", "4")
	defer func() {
		os.Unsetenv("NFTBAN_MAX_PREFIXES")
		os.Unsetenv("NFTBAN_MAX_ADDS_PER_RUN")
		os.Unsetenv("NFTBAN_GOMAXPROCS")
	}()

	lim := FromEnv()

	if lim.MaxPrefixesTotal != 500000 {
		t.Errorf("MaxPrefixesTotal: expected 500000, got %d", lim.MaxPrefixesTotal)
	}
	if lim.MaxAddsPerRun != 5000 {
		t.Errorf("MaxAddsPerRun: expected 5000, got %d", lim.MaxAddsPerRun)
	}
	if lim.GoMaxProcs != 4 {
		t.Errorf("GoMaxProcs: expected 4, got %d", lim.GoMaxProcs)
	}
}
