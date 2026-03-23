// =============================================================================
// NFTBan - Tests for watchdog base collectors
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_collector_base_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for watchdog base collectors"
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
	"context"
	"testing"
	"time"
)

// =============================================================================
// BaseCollector
// =============================================================================

func TestNewBaseCollector(t *testing.T) {
	bc := NewBaseCollector("test_collector")

	if bc.Name() != "test_collector" {
		t.Errorf("Name() = %q, want %q", bc.Name(), "test_collector")
	}
	if !bc.Enabled() {
		t.Error("Enabled() should be true by default")
	}
}

func TestBaseCollector_SetEnabled(t *testing.T) {
	bc := NewBaseCollector("test")

	bc.SetEnabled(false)
	if bc.Enabled() {
		t.Error("Enabled() should be false after SetEnabled(false)")
	}

	bc.SetEnabled(true)
	if !bc.Enabled() {
		t.Error("Enabled() should be true after SetEnabled(true)")
	}
}

func TestBaseCollector_Name(t *testing.T) {
	tests := []struct {
		name string
	}{
		{"process"},
		{"runtime"},
		{"system"},
		{"kernel"},
		{"nftables"},
		{""},
		{"a_very_long_collector_name"},
	}

	for _, tc := range tests {
		bc := NewBaseCollector(tc.name)
		if bc.Name() != tc.name {
			t.Errorf("Name() = %q, want %q", bc.Name(), tc.name)
		}
	}
}

// =============================================================================
// RuntimeCollector
// =============================================================================

func TestNewRuntimeCollector(t *testing.T) {
	rc := NewRuntimeCollector()
	if rc == nil {
		t.Fatal("NewRuntimeCollector() returned nil")
	}
	if rc.Name() != "runtime" {
		t.Errorf("Name() = %q, want %q", rc.Name(), "runtime")
	}
	if !rc.Enabled() {
		t.Error("should be enabled by default")
	}
}

func TestRuntimeCollector_Collect(t *testing.T) {
	rc := NewRuntimeCollector()
	snapshot := &Snapshot{}

	err := rc.Collect(context.Background(), snapshot)
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}

	if snapshot.Runtime.Goroutines <= 0 {
		t.Errorf("Goroutines = %d, want > 0", snapshot.Runtime.Goroutines)
	}
	if snapshot.Runtime.HeapAlloc == 0 {
		t.Error("HeapAlloc should be > 0")
	}
	if snapshot.Runtime.HeapInuse == 0 {
		t.Error("HeapInuse should be > 0")
	}
	if snapshot.Runtime.HeapSys == 0 {
		t.Error("HeapSys should be > 0")
	}
}

func TestRuntimeCollector_Disabled(t *testing.T) {
	rc := NewRuntimeCollector()
	rc.SetEnabled(false)

	snapshot := &Snapshot{}
	err := rc.Collect(context.Background(), snapshot)
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}

	// Should not populate anything when disabled
	if snapshot.Runtime.Goroutines != 0 {
		t.Errorf("Goroutines = %d, want 0 (disabled)", snapshot.Runtime.Goroutines)
	}
}

// =============================================================================
// NFTablesCollector
// =============================================================================

func TestNewNFTablesCollector(t *testing.T) {
	nc := NewNFTablesCollector(30 * time.Second)
	if nc == nil {
		t.Fatal("NewNFTablesCollector() returned nil")
	}
	if nc.Name() != "nftables" {
		t.Errorf("Name() = %q, want %q", nc.Name(), "nftables")
	}
	if nc.cacheDuration != 30*time.Second {
		t.Errorf("cacheDuration = %v, want 30s", nc.cacheDuration)
	}
}

func TestNewNFTablesCollector_DefaultCacheDuration(t *testing.T) {
	nc := NewNFTablesCollector(0)
	if nc.cacheDuration != 30*time.Second {
		t.Errorf("cacheDuration with 0 = %v, want 30s default", nc.cacheDuration)
	}
}

func TestNFTablesCollector_RecordApplyLatency(t *testing.T) {
	nc := NewNFTablesCollector(30 * time.Second)

	nc.RecordApplyLatency(500 * time.Millisecond)

	got := nc.GetLastApplyLatency()
	if got != 500*time.Millisecond {
		t.Errorf("GetLastApplyLatency() = %v, want 500ms", got)
	}
}

func TestNFTablesCollector_InvalidateCache(t *testing.T) {
	nc := NewNFTablesCollector(30 * time.Second)

	// Simulate a cached scan
	nc.lastFullScan = time.Now()
	nc.cachedRulesCount = 42

	nc.InvalidateCache()

	if !nc.lastFullScan.IsZero() {
		t.Error("lastFullScan should be zero after InvalidateCache")
	}
}

func TestNFTablesCollector_Disabled(t *testing.T) {
	nc := NewNFTablesCollector(30 * time.Second)
	nc.SetEnabled(false)

	snapshot := &Snapshot{
		NFTables: NFTablesMetrics{SetElements: map[string]int{}},
	}

	err := nc.Collect(context.Background(), snapshot)
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}

	// When disabled, should not modify snapshot (no nftables connection attempted)
	if snapshot.NFTables.RulesTotal != 0 {
		t.Errorf("RulesTotal = %d, want 0 (disabled)", snapshot.NFTables.RulesTotal)
	}
}

// =============================================================================
// KernelCollector
// =============================================================================

func TestNewKernelCollector(t *testing.T) {
	kc := NewKernelCollector()
	if kc == nil {
		t.Fatal("NewKernelCollector() returned nil")
	}
	if kc.Name() != "kernel" {
		t.Errorf("Name() = %q, want %q", kc.Name(), "kernel")
	}
}

func TestKernelCollector_GetSoftnetDropsRate(t *testing.T) {
	kc := NewKernelCollector()

	// Initial rate should be 0
	rate := kc.GetSoftnetDropsRate()
	if rate != 0 {
		t.Errorf("initial rate = %f, want 0", rate)
	}
}

func TestKernelCollector_Disabled(t *testing.T) {
	kc := NewKernelCollector()
	kc.SetEnabled(false)

	snapshot := &Snapshot{}
	err := kc.Collect(context.Background(), snapshot)
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}

	// Should not populate anything
	if snapshot.Kernel.ConntrackCount != 0 {
		t.Errorf("ConntrackCount = %d, want 0 (disabled)", snapshot.Kernel.ConntrackCount)
	}
}

// =============================================================================
// SystemCollector
// =============================================================================

func TestNewSystemCollector(t *testing.T) {
	sc := NewSystemCollector("/var/log")
	if sc == nil {
		t.Fatal("NewSystemCollector() returned nil")
	}
	if sc.Name() != "system" {
		t.Errorf("Name() = %q, want %q", sc.Name(), "system")
	}
	if sc.diskPath != "/var/log" {
		t.Errorf("diskPath = %q, want /var/log", sc.diskPath)
	}
}

func TestNewSystemCollector_DefaultDiskPath(t *testing.T) {
	sc := NewSystemCollector("")
	if sc.diskPath != "/var/log" {
		t.Errorf("diskPath with empty = %q, want /var/log", sc.diskPath)
	}
}

func TestSystemCollector_Disabled(t *testing.T) {
	sc := NewSystemCollector("/tmp")
	sc.SetEnabled(false)

	snapshot := &Snapshot{}
	err := sc.Collect(context.Background(), snapshot)
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}

	if snapshot.System.NumCPU != 0 {
		t.Errorf("NumCPU = %d, want 0 (disabled)", snapshot.System.NumCPU)
	}
}

// =============================================================================
// SystemCollector totalCPUTime
// =============================================================================

func TestTotalCPUTime(t *testing.T) {
	sc := NewSystemCollector("/tmp")

	stats := cpuStats{
		user:    100,
		nice:    10,
		system:  50,
		idle:    1000,
		iowait:  20,
		irq:     5,
		softirq: 3,
		steal:   2,
	}

	total := sc.totalCPUTime(stats)
	expected := uint64(100 + 10 + 50 + 1000 + 20 + 5 + 3 + 2)
	if total != expected {
		t.Errorf("totalCPUTime = %d, want %d", total, expected)
	}
}

func TestTotalCPUTime_AllZero(t *testing.T) {
	sc := NewSystemCollector("/tmp")
	stats := cpuStats{}

	total := sc.totalCPUTime(stats)
	if total != 0 {
		t.Errorf("totalCPUTime for zero stats = %d, want 0", total)
	}
}

// =============================================================================
// Collector Interface Compliance
// =============================================================================

func TestCollectorInterfaceCompliance(t *testing.T) {
	// Verify all collectors satisfy the Collector interface
	var _ Collector = &RuntimeCollector{}
	var _ Collector = &KernelCollector{}
	var _ Collector = &NFTablesCollector{}
	var _ Collector = &SystemCollector{}
	// ProcessCollector also implements it, but requires procfs.Self() which
	// may fail in constrained environments, so we test separately
}
