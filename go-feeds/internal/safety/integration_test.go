package safety

import (
	"testing"
)

// TestIntegrationDeltaProtection simulates a real scenario where
// feeds grow unexpectedly and delta protection kicks in
func TestIntegrationDeltaProtection(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  1000000,
		MaxProjectedBytes: 512 << 20, // 512 MB
		MaxPctOfAvail:     20,
		MaxAddsPerRun:     1000, // Allow max +1K per run
		MaxDelsPerRun:     200000,
		Enforce:           true,
		CacheDir:          tmpDir,
	}

	// Scenario: Initial feed with 50K IPs
	t.Log("Initial run: 50,000 IPs")
	err := Preflight(50000, 0, "hash_v1", lim)
	if err != nil {
		t.Fatalf("Initial run should pass: %v", err)
	}

	// Save snapshot
	snap := Snapshot{TotalV4: 50000, TotalV6: 0, Hash: "hash_v1"}
	if err := SaveSnapshot(tmpDir, snap); err != nil {
		t.Fatalf("Failed to save snapshot: %v", err)
	}

	// Scenario: Feed suddenly jumps to 900K (malicious or error)
	t.Log("Malicious run: 900,000 IPs (delta: +850K)")
	err = Preflight(900000, 0, "hash_v2", lim)
	if err == nil {
		t.Fatal("Should have blocked huge delta (+850K exceeds +1K limit)")
	}
	t.Logf("✅ Correctly blocked: %v", err)

	// Scenario: Normal growth (+500 IPs)
	t.Log("Normal run: 50,500 IPs (delta: +500)")
	err = Preflight(50500, 0, "hash_v3", lim)
	if err != nil {
		t.Fatalf("Normal growth should pass: %v", err)
	}
	t.Log("✅ Normal growth allowed")
}

// TestIntegrationMemoryExhaustion simulates memory protection
func TestIntegrationMemoryExhaustion(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  10000000,              // 10M cap
		MaxProjectedBytes: 50 * 1024 * 1024,      // 50 MB projected
		MaxPctOfAvail:     5,                     // Only 5% of available
		MaxAddsPerRun:     10000000,              // Large delta allowed
		MaxDelsPerRun:     10000000,              // Large delta allowed
		Enforce:           true,
		CacheDir:          tmpDir,
	}

	// Scenario: Try to load 1M IPs (~128 MB projected)
	t.Log("Memory exhaustion test: 1M IPs (~128 MB)")
	err := Preflight(1000000, 0, "hash_big", lim)
	if err == nil {
		t.Fatal("Should have blocked due to projected memory exceeding 50 MB")
	}
	t.Logf("✅ Correctly blocked: %v", err)

	// Scenario: Smaller feed that fits
	t.Log("Small feed test: 100K IPs (~12.8 MB)")
	err = Preflight(100000, 0, "hash_small", lim)
	if err != nil {
		t.Fatalf("Small feed should pass: %v", err)
	}
	t.Log("✅ Small feed allowed")
}

// TestIntegrationWarnMode verifies warn-only mode doesn't block
func TestIntegrationWarnMode(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  1000,
		MaxProjectedBytes: 1024,
		MaxPctOfAvail:     1,
		MaxAddsPerRun:     10,
		MaxDelsPerRun:     10,
		Enforce:           false, // WARN ONLY
		CacheDir:          tmpDir,
	}

	// Save initial state
	snap := Snapshot{TotalV4: 100, TotalV6: 0, Hash: "hash1"}
	if err := SaveSnapshot(tmpDir, snap); err != nil {
		t.Fatalf("Failed to save snapshot: %v", err)
	}

	// Try to violate all limits (should warn but not error)
	t.Log("Warn mode: violating all limits")
	err := Preflight(100000, 50000, "hash_huge", lim)
	if err != nil {
		t.Fatalf("Warn mode should not error, got: %v", err)
	}
	t.Log("✅ Warn mode allows override")
}

// TestIntegrationGradualGrowth simulates multiple runs with incremental growth
func TestIntegrationGradualGrowth(t *testing.T) {
	tmpDir := t.TempDir()

	lim := Limits{
		MaxPrefixesTotal:  100000,
		MaxProjectedBytes: 512 << 20,
		MaxPctOfAvail:     20,
		MaxAddsPerRun:     500,
		MaxDelsPerRun:     500,
		Enforce:           true,
		CacheDir:          tmpDir,
	}

	// Run 1: 1000 IPs
	t.Log("Run 1: 1000 IPs")
	if err := Preflight(1000, 0, "h1", lim); err != nil {
		t.Fatalf("Run 1 failed: %v", err)
	}
	SaveSnapshot(tmpDir, Snapshot{TotalV4: 1000, TotalV6: 0, Hash: "h1"})

	// Run 2: +400 IPs (allowed)
	t.Log("Run 2: +400 IPs")
	if err := Preflight(1400, 0, "h2", lim); err != nil {
		t.Fatalf("Run 2 failed: %v", err)
	}
	SaveSnapshot(tmpDir, Snapshot{TotalV4: 1400, TotalV6: 0, Hash: "h2"})

	// Run 3: +600 IPs (exceeds +500 limit, should block)
	t.Log("Run 3: +600 IPs (should block)")
	if err := Preflight(2000, 0, "h3", lim); err == nil {
		t.Fatal("Run 3 should have been blocked")
	}
	t.Log("✅ Correctly blocked excessive growth")

	// Run 4: +500 IPs exactly (should pass)
	t.Log("Run 4: +500 IPs (at limit)")
	if err := Preflight(1900, 0, "h4", lim); err != nil {
		t.Fatalf("Run 4 failed: %v", err)
	}
	t.Log("✅ Growth at exact limit allowed")
}
