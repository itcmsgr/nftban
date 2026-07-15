// =============================================================================
// NFTBan v1.80 - Effective-axis state machine tests (Phase E)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: aggregate
// Purpose: Tests for the Effective-axis state machine.
//
// meta:name="loginmon_pipeline_aggregate_effective_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="aggregate"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase E: Effective-axis state machine tests using real soak data"
//
// meta:inventory.files="effective_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package aggregate

import (
	"testing"
	"time"
)

func TestEvaluateWindow_NoEvents_Active(t *testing.T) {
	ws := WindowSnapshot{EventCount: 0, BanCount: 0, UniqueIPs: 0}
	es := EvaluateWindow(ws, "test")
	if es.State != EffectiveActive {
		t.Errorf("no events: got %v, want ACTIVE", es.State)
	}
	if es.Ratio != 1.0 {
		t.Errorf("no events ratio: got %v, want 1.0", es.Ratio)
	}
}

// Reproduces the host-a dovecot 24h soak data from Day 1 audit.
// host-a: 683 events / 43 bans = 6.3% → should be DEGRADED
func TestEvaluateWindow_Srv2_Degraded(t *testing.T) {
	ws := WindowSnapshot{
		Window:     1 * time.Hour,
		EventCount: 683,
		BanCount:   43,
		UniqueIPs:  12,
	}
	es := EvaluateWindow(ws, "dovecot")
	if es.State != EffectiveDegraded {
		t.Errorf("host-a dovecot: got %v, want DEGRADED", es.State)
	}
	if es.Ratio < 0.06 || es.Ratio > 0.07 {
		t.Errorf("ratio: got %v, want ~0.063", es.Ratio)
	}
}

// Reproduces the host-b dovecot 24h soak data from Day 1 audit.
// host-b: 868 events / 132 bans = 15.2% → should be ACTIVE (ratio > 10%)
func TestEvaluateWindow_Srv3_Active(t *testing.T) {
	ws := WindowSnapshot{
		Window:     1 * time.Hour,
		EventCount: 868,
		BanCount:   132,
		UniqueIPs:  15,
	}
	es := EvaluateWindow(ws, "dovecot")
	if es.State != EffectiveActive {
		t.Errorf("host-b dovecot: got %v, want ACTIVE", es.State)
	}
}

// Heavy volume, near-zero enforcement → FAILING
func TestEvaluateWindow_Failing(t *testing.T) {
	ws := WindowSnapshot{
		Window:     1 * time.Hour,
		EventCount: 500,
		BanCount:   10,
		UniqueIPs:  20,
	}
	es := EvaluateWindow(ws, "dovecot")
	// ratio = 10/500 = 2% < 5%, events >= 200, IPs >= 10
	if es.State != EffectiveFailing {
		t.Errorf("heavy no-enforcement: got %v, want FAILING", es.State)
	}
}

// Low volume — always ACTIVE regardless of ratio
func TestEvaluateWindow_LowVolume_AlwaysActive(t *testing.T) {
	ws := WindowSnapshot{
		Window:     1 * time.Hour,
		EventCount: 10,
		BanCount:   0,
		UniqueIPs:  3,
	}
	es := EvaluateWindow(ws, "test")
	if es.State != EffectiveActive {
		t.Errorf("low volume: got %v, want ACTIVE (insufficient signal)", es.State)
	}
}

// High ratio — always ACTIVE
func TestEvaluateWindow_HighRatio_Active(t *testing.T) {
	ws := WindowSnapshot{
		Window:     1 * time.Hour,
		EventCount: 100,
		BanCount:   80,
		UniqueIPs:  10,
	}
	es := EvaluateWindow(ws, "test")
	if es.State != EffectiveActive {
		t.Errorf("high ratio: got %v, want ACTIVE", es.State)
	}
}

func TestEvaluateHost_WorstWins(t *testing.T) {
	clock := time.Now()
	a := NewAggregator(AggregatorOptions{
		Windows: []time.Duration{1 * time.Hour},
		Now:     func() time.Time { return clock },
	})

	// dovecot: high volume, low ratio → DEGRADED
	for i := 0; i < 100; i++ {
		a.Ingest(mkEvent("dovecot", "1.2.3."+intToStr(i%20), "x@y", clock))
	}
	a.RecordBan("dovecot", clock) // 1 ban / 100 events = 1%

	// exim: low volume → ACTIVE
	for i := 0; i < 5; i++ {
		a.Ingest(mkEvent("exim", "5.6.7.8", "z@w", clock))
	}

	snap := a.Snapshot()
	host := EvaluateHost(snap)

	if host.Worst != EffectiveDegraded {
		t.Errorf("host worst: got %v, want DEGRADED (dovecot should pull it down)", host.Worst)
	}
	if len(host.Snapshots) != 2 {
		t.Errorf("snapshots: got %d, want 2 (dovecot + exim)", len(host.Snapshots))
	}
}

func TestEvaluateWindow_AdvisoryBand(t *testing.T) {
	// Events >= 50, ratio between 10-30% → ACTIVE with advisory
	ws := WindowSnapshot{
		Window:     1 * time.Hour,
		EventCount: 100,
		BanCount:   15,
		UniqueIPs:  8,
	}
	es := EvaluateWindow(ws, "test")
	if es.State != EffectiveActive {
		t.Errorf("advisory band: got %v, want ACTIVE", es.State)
	}
	if es.Reason == "active" {
		t.Errorf("advisory band should have advisory note, got plain 'active'")
	}
}
