// =============================================================================
// NFTBan - Tests for watchdog pressure calculator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_pressure_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for watchdog pressure calculator"
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
	"math"
	"testing"
	"time"
)

// =============================================================================
// clamp
// =============================================================================

func TestClamp(t *testing.T) {
	tests := []struct {
		name       string
		value      float64
		min        float64
		max        float64
		want       float64
	}{
		{"within range", 50, 0, 100, 50},
		{"at min", 0, 0, 100, 0},
		{"at max", 100, 0, 100, 100},
		{"below min", -10, 0, 100, 0},
		{"above max", 150, 0, 100, 100},
		{"negative range", -5, -10, -1, -5},
		{"same min max", 50, 10, 10, 10},
		{"zero range at zero", 0, 0, 0, 0},
		{"fractional value", 3.14, 0, 10, 3.14},
		{"large value clamped", 1e10, 0, 100, 100},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := clamp(tc.value, tc.min, tc.max)
			if got != tc.want {
				t.Errorf("clamp(%f, %f, %f) = %f, want %f", tc.value, tc.min, tc.max, got, tc.want)
			}
		})
	}
}

// =============================================================================
// NewPressureCalculator
// =============================================================================

func TestNewPressureCalculator(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	if pc == nil {
		t.Fatal("NewPressureCalculator() returned nil")
	}
	if pc.maxRSSHistory != 12 {
		t.Errorf("maxRSSHistory = %d, want 12", pc.maxRSSHistory)
	}
	if len(pc.rssHistory) != 0 {
		t.Errorf("rssHistory len = %d, want 0", len(pc.rssHistory))
	}
}

// =============================================================================
// CPU Score Calculation
// =============================================================================

func TestCalculateCPUScore(t *testing.T) {
	cfg := testConfig()
	cfg.CPUCritPercent = 80
	cfg.LoadNormalizedCrit = 4.0
	cfg.SoftnetDropsRateCrit = 100

	tests := []struct {
		name     string
		snapshot Snapshot
		wantMin  float64
		wantMax  float64
	}{
		{
			name: "zero CPU",
			snapshot: Snapshot{
				Process: ProcessMetrics{CPUPct: 0},
				System:  SystemMetrics{LoadAvg5: 0, NumCPU: 4},
				Kernel:  KernelMetrics{SoftnetDrops: 0},
			},
			wantMin: 0,
			wantMax: 1,
		},
		{
			name: "high CPU low load",
			snapshot: Snapshot{
				Process: ProcessMetrics{CPUPct: 80},
				System:  SystemMetrics{LoadAvg5: 0, NumCPU: 4},
				Kernel:  KernelMetrics{SoftnetDrops: 0},
			},
			wantMin: 49, // 80/80 * 50 = 50
			wantMax: 51,
		},
		{
			name: "high load low CPU",
			snapshot: Snapshot{
				Process: ProcessMetrics{CPUPct: 0},
				System:  SystemMetrics{LoadAvg5: 16.0, NumCPU: 4},
				Kernel:  KernelMetrics{SoftnetDrops: 0},
			},
			wantMin: 29, // normalized=4.0, 4.0/4.0*30=30
			wantMax: 31,
		},
		{
			name: "max everything",
			snapshot: Snapshot{
				Process: ProcessMetrics{CPUPct: 100},
				System:  SystemMetrics{LoadAvg5: 100.0, NumCPU: 1},
				Kernel:  KernelMetrics{SoftnetDrops: 0},
			},
			wantMin: 79, // 50 (CPU) + 30 (load) = 80, but both clamped
			wantMax: 81,
		},
		{
			name: "zero CPUs handled gracefully",
			snapshot: Snapshot{
				Process: ProcessMetrics{CPUPct: 40},
				System:  SystemMetrics{LoadAvg5: 10.0, NumCPU: 0},
				Kernel:  KernelMetrics{SoftnetDrops: 0},
			},
			wantMin: 24, // 40/80*50=25 (load skipped because NumCPU=0)
			wantMax: 26,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			pc := NewPressureCalculator(cfg)
			tc.snapshot.Timestamp = time.Now()
			score := pc.calculateCPUScore(&tc.snapshot)
			if score < tc.wantMin || score > tc.wantMax {
				t.Errorf("CPU score = %f, want [%f, %f]", score, tc.wantMin, tc.wantMax)
			}
		})
	}
}

// =============================================================================
// MEM Score Calculation
// =============================================================================

func TestCalculateMEMScore(t *testing.T) {
	cfg := testConfig()
	cfg.MemBudgetBytes = 1024 * 1024 * 1024 // 1GB
	cfg.RSSCritPercentOfBudget = 95
	cfg.HeapCritPercentOfLimit = 90

	tests := []struct {
		name     string
		snapshot Snapshot
		wantMin  float64
		wantMax  float64
	}{
		{
			name: "zero memory",
			snapshot: Snapshot{
				Process: ProcessMetrics{RSS: 0},
				Runtime: RuntimeMetrics{HeapInuse: 0, GCCPUFraction: 0, GOMEMLIMIT: -1},
			},
			wantMin: 0,
			wantMax: 1,
		},
		{
			name: "half budget RSS",
			snapshot: Snapshot{
				Process: ProcessMetrics{RSS: 512 * 1024 * 1024}, // 50% of 1GB
				Runtime: RuntimeMetrics{HeapInuse: 0, GCCPUFraction: 0, GOMEMLIMIT: -1},
			},
			wantMin: 20, // 50%/95% * 40 ~= 21
			wantMax: 22,
		},
		{
			name: "high GC fraction",
			snapshot: Snapshot{
				Process: ProcessMetrics{RSS: 0},
				Runtime: RuntimeMetrics{HeapInuse: 0, GCCPUFraction: 0.10, GOMEMLIMIT: -1},
			},
			wantMin: 14, // 0.10/0.10 * 15 = 15
			wantMax: 16,
		},
		{
			name: "heap near GOMEMLIMIT",
			snapshot: Snapshot{
				Process: ProcessMetrics{RSS: 0},
				Runtime: RuntimeMetrics{
					HeapInuse:     900 * 1024 * 1024, // 900MB
					GCCPUFraction: 0,
					GOMEMLIMIT:    1024 * 1024 * 1024, // 1GB
				},
			},
			wantMin: 28, // 90%/90% * 30 ~= 29.3
			wantMax: 31,
		},
		{
			name: "zero budget handled",
			snapshot: Snapshot{
				Process: ProcessMetrics{RSS: 100},
				Runtime: RuntimeMetrics{HeapInuse: 0, GCCPUFraction: 0, GOMEMLIMIT: -1},
			},
			wantMin: 0,
			wantMax: 1,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			pc := NewPressureCalculator(cfg)
			// For zero budget test, override
			localCfg := *cfg
			if tc.name == "zero budget handled" {
				localCfg.MemBudgetBytes = 0
				pc = NewPressureCalculator(&localCfg)
			}
			tc.snapshot.Timestamp = time.Now()
			score := pc.calculateMEMScore(&tc.snapshot)
			if score < tc.wantMin || score > tc.wantMax {
				t.Errorf("MEM score = %f, want [%f, %f]", score, tc.wantMin, tc.wantMax)
			}
		})
	}
}

// =============================================================================
// IO Score Calculation
// =============================================================================

func TestCalculateIOScore(t *testing.T) {
	cfg := testConfig()
	cfg.IOWaitCritPercent = 40
	cfg.DiskUseCritPercent = 95

	tests := []struct {
		name     string
		snapshot Snapshot
		wantMin  float64
		wantMax  float64
	}{
		{
			name: "zero IO",
			snapshot: Snapshot{
				System: SystemMetrics{IOWaitPct: 0, DiskUsePct: 0},
			},
			wantMin: 0,
			wantMax: 1,
		},
		{
			name: "high iowait",
			snapshot: Snapshot{
				System: SystemMetrics{IOWaitPct: 40, DiskUsePct: 0},
			},
			wantMin: 59, // 40/40*60=60
			wantMax: 61,
		},
		{
			name: "high disk usage",
			snapshot: Snapshot{
				System: SystemMetrics{IOWaitPct: 0, DiskUsePct: 95},
			},
			wantMin: 39, // 95/95*40=40
			wantMax: 41,
		},
		{
			name: "both maxed",
			snapshot: Snapshot{
				System: SystemMetrics{IOWaitPct: 80, DiskUsePct: 100},
			},
			wantMin: 99, // 60+40=100 (both clamped to max contributions)
			wantMax: 100,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			pc := NewPressureCalculator(cfg)
			score := pc.calculateIOScore(&tc.snapshot)
			if score < tc.wantMin || score > tc.wantMax {
				t.Errorf("IO score = %f, want [%f, %f]", score, tc.wantMin, tc.wantMax)
			}
		})
	}
}

// =============================================================================
// NET Score Calculation
// =============================================================================

func TestCalculateNETScore(t *testing.T) {
	cfg := testConfig()
	cfg.ConntrackUtilCrit = 0.9
	cfg.SoftnetDropsRateCrit = 100

	tests := []struct {
		name     string
		snapshot Snapshot
		wantMin  float64
		wantMax  float64
	}{
		{
			name: "zero network",
			snapshot: Snapshot{
				Kernel:   KernelMetrics{ConntrackUtilization: 0, SoftnetDrops: 0},
				NFTables: NFTablesMetrics{LastApplyLatency: 0},
			},
			wantMin: 0,
			wantMax: 1,
		},
		{
			name: "high conntrack",
			snapshot: Snapshot{
				Kernel:   KernelMetrics{ConntrackUtilization: 0.9, SoftnetDrops: 0},
				NFTables: NFTablesMetrics{LastApplyLatency: 0},
			},
			wantMin: 49, // 0.9/0.9*50=50
			wantMax: 51,
		},
		{
			name: "high nft latency",
			snapshot: Snapshot{
				Kernel:   KernelMetrics{ConntrackUtilization: 0, SoftnetDrops: 0},
				NFTables: NFTablesMetrics{LastApplyLatency: 1.0},
			},
			wantMin: 19, // 1.0/1.0*20=20
			wantMax: 21,
		},
		{
			name: "zero conntrack crit threshold",
			snapshot: Snapshot{
				Kernel:   KernelMetrics{ConntrackUtilization: 0.5, SoftnetDrops: 0},
				NFTables: NFTablesMetrics{LastApplyLatency: 0},
			},
			wantMin: 0,
			wantMax: 100,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			localCfg := *cfg
			if tc.name == "zero conntrack crit threshold" {
				localCfg.ConntrackUtilCrit = 0
			}
			pc := NewPressureCalculator(&localCfg)
			tc.snapshot.Timestamp = time.Now()
			score := pc.calculateNETScore(&tc.snapshot)
			if score < tc.wantMin || score > tc.wantMax {
				t.Errorf("NET score = %f, want [%f, %f]", score, tc.wantMin, tc.wantMax)
			}
		})
	}
}

// =============================================================================
// Calculate (full pipeline)
// =============================================================================

func TestCalculate_AllDimensionsPresent(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	snapshot := &Snapshot{
		Timestamp: time.Now(),
		Process:   ProcessMetrics{CPUPct: 40, RSS: 100 * 1024 * 1024},
		Runtime:   RuntimeMetrics{HeapInuse: 50 * 1024 * 1024, GCCPUFraction: 0.01, GOMEMLIMIT: -1},
		System:    SystemMetrics{LoadAvg5: 2.0, NumCPU: 4, IOWaitPct: 10, DiskUsePct: 50},
		Kernel:    KernelMetrics{ConntrackUtilization: 0.3, SoftnetDrops: 0},
		NFTables:  NFTablesMetrics{LastApplyLatency: 0.1, SetElements: map[string]int{}},
	}

	scores := pc.Calculate(snapshot)

	for _, dim := range AllDimensions() {
		score, ok := scores[dim]
		if !ok {
			t.Errorf("missing score for dimension %s", dim)
			continue
		}
		if score < 0 || score > 100 {
			t.Errorf("score for %s = %f, want [0, 100]", dim, score)
		}
	}
}

func TestCalculate_ScoresAlwaysClamped(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	// Use extreme values
	snapshot := &Snapshot{
		Timestamp: time.Now(),
		Process:   ProcessMetrics{CPUPct: 1000, RSS: math.MaxUint64},
		Runtime:   RuntimeMetrics{HeapInuse: math.MaxUint64, GCCPUFraction: 1.0, GOMEMLIMIT: 1},
		System:    SystemMetrics{LoadAvg5: 1000, NumCPU: 1, IOWaitPct: 100, DiskUsePct: 100},
		Kernel:    KernelMetrics{ConntrackUtilization: 10.0, SoftnetDrops: 0},
		NFTables:  NFTablesMetrics{LastApplyLatency: 100.0, SetElements: map[string]int{}},
	}

	scores := pc.Calculate(snapshot)

	for _, dim := range AllDimensions() {
		if scores[dim] > 100 {
			t.Errorf("score for %s = %f, exceeds 100", dim, scores[dim])
		}
		if scores[dim] < 0 {
			t.Errorf("score for %s = %f, below 0", dim, scores[dim])
		}
	}
}

// =============================================================================
// RSS Slope Calculation
// =============================================================================

func TestCalculateRSSSlope_NotEnoughData(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	slope := pc.calculateRSSSlope()
	if slope != 0 {
		t.Errorf("slope with no data = %f, want 0", slope)
	}

	// Add one point
	pc.rssHistory = append(pc.rssHistory, rssPoint{
		timestamp: time.Now(),
		rss:       1000,
	})
	slope = pc.calculateRSSSlope()
	if slope != 0 {
		t.Errorf("slope with one point = %f, want 0", slope)
	}
}

func TestCalculateRSSSlope_StableMemory(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	now := time.Now()
	for i := 0; i < 5; i++ {
		pc.rssHistory = append(pc.rssHistory, rssPoint{
			timestamp: now.Add(time.Duration(i) * 5 * time.Second),
			rss:       100 * 1024 * 1024, // constant 100MB
		})
	}

	slope := pc.calculateRSSSlope()
	if slope != 0 {
		t.Errorf("slope for stable memory = %f, want 0", slope)
	}
}

func TestCalculateRSSSlope_GrowingMemory(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	now := time.Now()
	// Linear growth: 100MB + 10MB per 5 seconds = 2MB/s
	for i := 0; i < 5; i++ {
		pc.rssHistory = append(pc.rssHistory, rssPoint{
			timestamp: now.Add(time.Duration(i) * 5 * time.Second),
			rss:       uint64(100+i*10) * 1024 * 1024,
		})
	}

	slope := pc.calculateRSSSlope()
	if slope <= 0 {
		t.Errorf("slope for growing memory = %f, want > 0", slope)
	}

	// Rough check: ~2MB/s expected
	expectedBytesPerSec := 2.0 * 1024 * 1024
	tolerance := 0.2
	if math.Abs(slope-expectedBytesPerSec)/expectedBytesPerSec > tolerance {
		t.Errorf("slope = %f bytes/sec, expected ~%f bytes/sec (tolerance %.0f%%)",
			slope, expectedBytesPerSec, tolerance*100)
	}
}

func TestCalculateRSSSlope_ShrinkingMemory(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	now := time.Now()
	for i := 0; i < 5; i++ {
		pc.rssHistory = append(pc.rssHistory, rssPoint{
			timestamp: now.Add(time.Duration(i) * 5 * time.Second),
			rss:       uint64(200-i*10) * 1024 * 1024,
		})
	}

	slope := pc.calculateRSSSlope()
	if slope >= 0 {
		t.Errorf("slope for shrinking memory = %f, want < 0", slope)
	}
}

func TestUpdateRSSHistory_Trimming(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)
	pc.maxRSSHistory = 3

	for i := 0; i < 5; i++ {
		snapshot := &Snapshot{
			Timestamp: time.Now().Add(time.Duration(i) * time.Second),
			Process:   ProcessMetrics{RSS: uint64(i * 1024)},
		}
		pc.updateRSSHistory(snapshot)
	}

	if len(pc.rssHistory) != 3 {
		t.Errorf("rssHistory len = %d, want 3 (maxRSSHistory)", len(pc.rssHistory))
	}

	// Should have the last 3 entries
	if pc.rssHistory[0].rss != 2*1024 {
		t.Errorf("first entry RSS = %d, want %d", pc.rssHistory[0].rss, 2*1024)
	}
}

// =============================================================================
// Softnet Drops Rate
// =============================================================================

func TestUpdateSoftnetDropsRate_FirstCall(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	snapshot := &Snapshot{
		Timestamp: time.Now(),
		Kernel:    KernelMetrics{SoftnetDrops: 100},
	}

	pc.updateSoftnetDropsRate(snapshot)

	if pc.softnetDropsRate != 0 {
		t.Errorf("rate after first call = %f, want 0", pc.softnetDropsRate)
	}
	if pc.lastSoftnetDrops != 100 {
		t.Errorf("lastSoftnetDrops = %d, want 100", pc.lastSoftnetDrops)
	}
}

func TestUpdateSoftnetDropsRate_SubsequentCalls(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	now := time.Now()

	// First call
	snapshot1 := &Snapshot{
		Timestamp: now,
		Kernel:    KernelMetrics{SoftnetDrops: 100},
	}
	pc.updateSoftnetDropsRate(snapshot1)

	// Second call, 10 seconds later with 200 more drops
	snapshot2 := &Snapshot{
		Timestamp: now.Add(10 * time.Second),
		Kernel:    KernelMetrics{SoftnetDrops: 300},
	}
	pc.updateSoftnetDropsRate(snapshot2)

	// Rate should be (300-100)/10 = 20 drops/sec
	expectedRate := 20.0
	tolerance := 0.1
	if math.Abs(pc.softnetDropsRate-expectedRate) > tolerance {
		t.Errorf("rate = %f, want %f", pc.softnetDropsRate, expectedRate)
	}
}

// =============================================================================
// Edge: calculateRSSSlope with same timestamp (denominator = 0)
// =============================================================================

func TestCalculateRSSSlope_SameTimestamps(t *testing.T) {
	cfg := testConfig()
	pc := NewPressureCalculator(cfg)

	now := time.Now()
	for i := 0; i < 5; i++ {
		pc.rssHistory = append(pc.rssHistory, rssPoint{
			timestamp: now, // all same timestamp
			rss:       uint64(i * 1024),
		})
	}

	slope := pc.calculateRSSSlope()
	if slope != 0 {
		t.Errorf("slope with same timestamps = %f, want 0", slope)
	}
}

// =============================================================================
// MEM Score with RSS Slope
// =============================================================================

func TestCalculateMEMScore_WithRSSSlope(t *testing.T) {
	cfg := testConfig()
	cfg.MemBudgetBytes = 1024 * 1024 * 1024 // 1GB
	pc := NewPressureCalculator(cfg)

	// Simulate growing RSS over time
	now := time.Now()
	for i := 0; i < 10; i++ {
		snapshot := &Snapshot{
			Timestamp: now.Add(time.Duration(i) * 5 * time.Second),
			Process:   ProcessMetrics{RSS: uint64(100+i*50) * 1024 * 1024},
			Runtime:   RuntimeMetrics{GOMEMLIMIT: -1},
		}
		pc.updateRSSHistory(snapshot)
	}

	// Now calculate with non-zero RSS slope
	snapshot := &Snapshot{
		Timestamp: now.Add(50 * time.Second),
		Process:   ProcessMetrics{RSS: 600 * 1024 * 1024},
		Runtime:   RuntimeMetrics{GOMEMLIMIT: -1, GCCPUFraction: 0},
	}

	score := pc.calculateMEMScore(snapshot)

	// Should include RSS contribution + slope contribution
	if score <= 0 {
		t.Errorf("MEM score with growing RSS = %f, want > 0", score)
	}
}

// =============================================================================
// CPU Score with Softnet Drops
// =============================================================================

func TestCalculateCPUScore_WithSoftnetDrops(t *testing.T) {
	cfg := testConfig()
	cfg.SoftnetDropsRateCrit = 100
	pc := NewPressureCalculator(cfg)

	now := time.Now()

	// Initialize softnet baseline
	snapshot1 := &Snapshot{
		Timestamp: now,
		Process:   ProcessMetrics{CPUPct: 0},
		System:    SystemMetrics{NumCPU: 4, LoadAvg5: 0},
		Kernel:    KernelMetrics{SoftnetDrops: 0},
	}
	pc.updateSoftnetDropsRate(snapshot1)

	// High softnet drops rate
	snapshot2 := &Snapshot{
		Timestamp: now.Add(10 * time.Second),
		Process:   ProcessMetrics{CPUPct: 0},
		System:    SystemMetrics{NumCPU: 4, LoadAvg5: 0},
		Kernel:    KernelMetrics{SoftnetDrops: 1000},
	}
	pc.updateSoftnetDropsRate(snapshot2)

	score := pc.calculateCPUScore(snapshot2)

	// Rate = 100 drops/sec = softnetDropsRateCrit
	// Contribution = (100/100) * 20 = 20
	if score < 19 || score > 21 {
		t.Errorf("CPU score with softnet drops = %f, want ~20", score)
	}
}
