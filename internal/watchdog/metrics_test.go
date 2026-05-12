// =============================================================================
// NFTBan - Tests for watchdog Prometheus metrics emission wiring
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_metrics_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-12"
// meta:description="Tests for D-METR-2 fix — action emission wiring via SetOnAction"
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
//
// Regression coverage for v1.111 PR-M2: nftban_watchdog_action_total and
// nftban_watchdog_last_action_timestamp_seconds were registered via promauto
// in metrics.go but the MetricsExporter.RecordAction emission method was
// orphaned (never called from production code). The fix mirrors the existing
// onMetrics/SetOnMetrics callback pattern with onAction/SetOnAction and
// wires it in cmd/nftband/daemon_init.go.
//
// These tests verify the callback contract, not the Prometheus counter values
// directly, since prometheus/client_golang.NewCounterVec semantics are
// already covered by the upstream library and adding a test dependency on
// prometheus/testutil is not necessary for the wiring fix.
// =============================================================================

package watchdog

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// =============================================================================
// SetOnAction wiring (D-METR-2 fix)
// =============================================================================

// TestSetOnAction_NilSafe verifies handleAction does not panic when no
// onAction callback has been set — the default state for any Watchdog that
// has not been wired (e.g., short-lived tests or future callers).
func TestSetOnAction_NilSafe(t *testing.T) {
	w, err := New(testConfig(), NewRuntimeControls())
	if err != nil {
		t.Fatalf("New() error: %v", err)
	}

	// No SetOnAction call — onAction is nil
	action := Action{
		Type:      ActionThrottle,
		Timestamp: time.Now(),
		Reason:    "test_nil_safe",
		Success:   true,
	}

	// Should not panic even with nil callback
	w.handleAction(action)
}

// TestSetOnAction_Fires verifies that setting a callback then invoking
// handleAction dispatches the action to the callback. This is the contract
// that D-METR-2 relies on: production wiring in daemon_init.go does
// SetOnAction(func(a) { d.wdMetrics.RecordAction(a) }), so the counter
// emission depends on this callback firing.
func TestSetOnAction_Fires(t *testing.T) {
	w, err := New(testConfig(), NewRuntimeControls())
	if err != nil {
		t.Fatalf("New() error: %v", err)
	}

	var got Action
	var fired int32
	w.SetOnAction(func(a Action) {
		atomic.AddInt32(&fired, 1)
		got = a
	})

	want := Action{
		Type:      ActionDisableOptional,
		Timestamp: time.Date(2026, 5, 12, 10, 0, 0, 0, time.UTC),
		Reason:    "test_fires",
		Success:   true,
	}

	w.handleAction(want)

	if n := atomic.LoadInt32(&fired); n != 1 {
		t.Fatalf("onAction callback fired %d times, want 1", n)
	}
	if got.Type != want.Type {
		t.Errorf("Action.Type = %q, want %q", got.Type, want.Type)
	}
	if !got.Timestamp.Equal(want.Timestamp) {
		t.Errorf("Action.Timestamp = %v, want %v", got.Timestamp, want.Timestamp)
	}
	if got.Reason != want.Reason {
		t.Errorf("Action.Reason = %q, want %q", got.Reason, want.Reason)
	}
}

// TestSetOnAction_Replace verifies SetOnAction replaces a previously-set
// callback so reconfiguration is supported (mirrors SetOnMetrics behavior).
func TestSetOnAction_Replace(t *testing.T) {
	w, err := New(testConfig(), NewRuntimeControls())
	if err != nil {
		t.Fatalf("New() error: %v", err)
	}

	var firstFired, secondFired int32
	w.SetOnAction(func(_ Action) { atomic.AddInt32(&firstFired, 1) })
	w.SetOnAction(func(_ Action) { atomic.AddInt32(&secondFired, 1) })

	w.handleAction(Action{Type: ActionFreeOSMemory, Timestamp: time.Now(), Reason: "test_replace"})

	if n := atomic.LoadInt32(&firstFired); n != 0 {
		t.Errorf("first callback fired %d times after replacement, want 0", n)
	}
	if n := atomic.LoadInt32(&secondFired); n != 1 {
		t.Errorf("second callback fired %d times, want 1", n)
	}
}

// TestSetOnAction_ConcurrentSetAndDispatch verifies the mu.Lock pattern in
// SetOnAction/handleAction is race-free under concurrent reconfiguration
// and dispatch. Mirrors the existing onMetrics callback synchronization.
func TestSetOnAction_ConcurrentSetAndDispatch(t *testing.T) {
	w, err := New(testConfig(), NewRuntimeControls())
	if err != nil {
		t.Fatalf("New() error: %v", err)
	}

	var fired int32
	cb := func(_ Action) { atomic.AddInt32(&fired, 1) }

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			w.SetOnAction(cb)
		}()
		go func() {
			defer wg.Done()
			w.handleAction(Action{Type: ActionThrottle, Timestamp: time.Now(), Reason: "race"})
		}()
	}
	wg.Wait()

	// At least one dispatch should have observed a non-nil callback. We do
	// not assert a specific count because dispatch and set are racing; the
	// test's primary value is exercising the lock under -race.
	if atomic.LoadInt32(&fired) == 0 {
		t.Logf("note: zero callbacks fired under heavy race (acceptable; primary check is -race detector)")
	}
}

// =============================================================================
// MetricsExporter.RecordAction smoke
// =============================================================================

// TestMetricsExporter_RecordAction_Smoke verifies the previously-orphaned
// RecordAction emission method is callable end-to-end. Pre-PR-M2 this method
// was defined but never called from production code; after the wiring fix
// daemon_init.go invokes it from the SetOnAction callback.
func TestMetricsExporter_RecordAction_Smoke(t *testing.T) {
	m := NewMetricsExporter()
	if m == nil {
		t.Fatal("NewMetricsExporter() returned nil")
	}

	// Should complete without panic for every documented ActionType.
	types := []ActionType{
		ActionThrottle,
		ActionDisableOptional,
		ActionFreeOSMemory,
		ActionDegradeMode,
		ActionProfileCPU,
		ActionProfileHeap,
		ActionProfileGoroutine,
	}
	now := time.Now()
	for _, at := range types {
		m.RecordAction(Action{Type: at, Timestamp: now, Reason: "smoke", Success: true})
	}
}
