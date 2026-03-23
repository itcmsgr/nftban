// =============================================================================
// NFTBan v1.0 - Event Bus Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="bus_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for event bus pub/sub, worker pool, and metrics"
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

package eventbus

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// =============================================================================
// Severity Tests
// =============================================================================

func TestSeverity_String(t *testing.T) {
	tests := []struct {
		name     string
		severity Severity
		want     string
	}{
		{"debug", SeverityDebug, "DEBUG"},
		{"info", SeverityInfo, "INFO"},
		{"warning", SeverityWarning, "WARNING"},
		{"critical", SeverityCritical, "CRITICAL"},
		{"unknown", Severity(99), "UNKNOWN"},
		{"negative", Severity(-1), "UNKNOWN"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.severity.String()
			if got != tt.want {
				t.Errorf("Severity(%d).String() = %q, want %q", tt.severity, got, tt.want)
			}
		})
	}
}

// =============================================================================
// Event Builder Tests
// =============================================================================

func TestNewEvent(t *testing.T) {
	e := NewEvent(EventBan, "test-source")

	if e.Type != EventBan {
		t.Errorf("expected event type %q, got %q", EventBan, e.Type)
	}
	if e.Source != "test-source" {
		t.Errorf("expected source %q, got %q", "test-source", e.Source)
	}
	if e.Severity != SeverityInfo {
		t.Errorf("expected default severity INFO, got %v", e.Severity)
	}
	if e.ID == "" {
		t.Error("expected non-empty event ID")
	}
	if e.Timestamp.IsZero() {
		t.Error("expected non-zero timestamp")
	}
	if e.Data == nil {
		t.Error("expected non-nil Data map")
	}
}

func TestEvent_WithIP(t *testing.T) {
	e := NewEvent(EventBan, "test").WithIP("1.2.3.4")
	if e.IP != "1.2.3.4" {
		t.Errorf("expected IP %q, got %q", "1.2.3.4", e.IP)
	}
}

func TestEvent_WithUser(t *testing.T) {
	e := NewEvent(EventLoginFail, "test").WithUser("admin")
	if e.User != "admin" {
		t.Errorf("expected User %q, got %q", "admin", e.User)
	}
}

func TestEvent_WithMessage(t *testing.T) {
	e := NewEvent(EventBan, "test").WithMessage("blocked for scanning")
	if e.Message != "blocked for scanning" {
		t.Errorf("expected Message %q, got %q", "blocked for scanning", e.Message)
	}
}

func TestEvent_WithSeverity(t *testing.T) {
	e := NewEvent(EventBan, "test").WithSeverity(SeverityCritical)
	if e.Severity != SeverityCritical {
		t.Errorf("expected severity CRITICAL, got %v", e.Severity)
	}
}

func TestEvent_WithData(t *testing.T) {
	e := NewEvent(EventBan, "test").
		WithData("reason", "portscan").
		WithData("count", 5)

	if e.Data["reason"] != "portscan" {
		t.Errorf("expected Data[reason]=%q, got %q", "portscan", e.Data["reason"])
	}
	if e.Data["count"] != 5 {
		t.Errorf("expected Data[count]=5, got %v", e.Data["count"])
	}
}

func TestEvent_WithDataNilMap(t *testing.T) {
	// Test that WithData handles nil Data map gracefully
	e := Event{}
	e = e.WithData("key", "value")
	if e.Data == nil {
		t.Error("expected Data map to be created")
	}
	if e.Data["key"] != "value" {
		t.Errorf("expected Data[key]=%q, got %q", "value", e.Data["key"])
	}
}

func TestEvent_BuilderChaining(t *testing.T) {
	e := NewEvent(EventBan, "test-module").
		WithIP("10.0.0.1").
		WithUser("attacker").
		WithMessage("banned for DDoS").
		WithSeverity(SeverityCritical).
		WithData("duration", "1h")

	if e.IP != "10.0.0.1" {
		t.Errorf("IP = %q, want %q", e.IP, "10.0.0.1")
	}
	if e.User != "attacker" {
		t.Errorf("User = %q, want %q", e.User, "attacker")
	}
	if e.Message != "banned for DDoS" {
		t.Errorf("Message = %q, want %q", e.Message, "banned for DDoS")
	}
	if e.Severity != SeverityCritical {
		t.Errorf("Severity = %v, want CRITICAL", e.Severity)
	}
	if e.Data["duration"] != "1h" {
		t.Errorf("Data[duration] = %v, want %q", e.Data["duration"], "1h")
	}
}

// =============================================================================
// generateID Tests
// =============================================================================

func TestGenerateID_Uniqueness(t *testing.T) {
	ids := make(map[string]bool)
	for i := 0; i < 1000; i++ {
		id := generateID()
		if id == "" {
			t.Fatal("generated empty ID")
		}
		if ids[id] {
			t.Fatalf("duplicate ID generated: %s", id)
		}
		ids[id] = true
	}
}

func TestGenerateID_Length(t *testing.T) {
	id := generateID()
	// 8 bytes hex-encoded = 16 characters
	if len(id) != 16 {
		t.Errorf("expected ID length 16, got %d: %q", len(id), id)
	}
}

// =============================================================================
// Bus Creation Tests
// =============================================================================

func TestNew(t *testing.T) {
	bus := New()
	defer bus.Close()

	stats := bus.Stats()
	if stats.Workers != DefaultWorkerCount {
		t.Errorf("expected %d workers, got %d", DefaultWorkerCount, stats.Workers)
	}
	if stats.QueueSize != DefaultQueueSize {
		t.Errorf("expected queue size %d, got %d", DefaultQueueSize, stats.QueueSize)
	}
	if stats.Subscriptions != 0 {
		t.Errorf("expected 0 subscriptions, got %d", stats.Subscriptions)
	}
}

func TestNewWithConfig(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	stats := bus.Stats()
	if stats.Workers != 4 {
		t.Errorf("expected 4 workers, got %d", stats.Workers)
	}
	if stats.QueueSize != 64 {
		t.Errorf("expected queue size 64, got %d", stats.QueueSize)
	}
}

func TestNewWithConfig_InvalidValues(t *testing.T) {
	// Zero/negative values should use defaults
	bus := NewWithConfig(0, -1)
	defer bus.Close()

	stats := bus.Stats()
	if stats.Workers != DefaultWorkerCount {
		t.Errorf("expected default workers %d, got %d", DefaultWorkerCount, stats.Workers)
	}
	if stats.QueueSize != DefaultQueueSize {
		t.Errorf("expected default queue size %d, got %d", DefaultQueueSize, stats.QueueSize)
	}
}

// =============================================================================
// Subscribe/Unsubscribe Tests
// =============================================================================

func TestSubscribe(t *testing.T) {
	bus := New()
	defer bus.Close()

	id := bus.Subscribe(EventBan, func(e Event) {})

	if id == "" {
		t.Error("expected non-empty subscription ID")
	}

	stats := bus.Stats()
	if stats.Subscriptions != 1 {
		t.Errorf("expected 1 subscription, got %d", stats.Subscriptions)
	}
}

func TestSubscribeAll(t *testing.T) {
	bus := New()
	defer bus.Close()

	id := bus.SubscribeAll(func(e Event) {})

	if id == "" {
		t.Error("expected non-empty subscription ID")
	}

	stats := bus.Stats()
	if stats.Subscriptions != 1 {
		t.Errorf("expected 1 subscription, got %d", stats.Subscriptions)
	}
}

func TestSubscribeMultiple(t *testing.T) {
	bus := New()
	defer bus.Close()

	ids := bus.SubscribeMultiple(
		[]EventType{EventBan, EventUnban, EventLoginFail},
		func(e Event) {},
	)

	if len(ids) != 3 {
		t.Errorf("expected 3 subscription IDs, got %d", len(ids))
	}

	stats := bus.Stats()
	if stats.Subscriptions != 3 {
		t.Errorf("expected 3 subscriptions, got %d", stats.Subscriptions)
	}
}

func TestUnsubscribe(t *testing.T) {
	bus := New()
	defer bus.Close()

	id := bus.Subscribe(EventBan, func(e Event) {})
	ok := bus.Unsubscribe(id)

	if !ok {
		t.Error("expected successful unsubscribe")
	}

	stats := bus.Stats()
	if stats.Subscriptions != 0 {
		t.Errorf("expected 0 subscriptions after unsubscribe, got %d", stats.Subscriptions)
	}
}

func TestUnsubscribe_NotFound(t *testing.T) {
	bus := New()
	defer bus.Close()

	ok := bus.Unsubscribe("nonexistent-id")
	if ok {
		t.Error("expected false for nonexistent subscription")
	}
}

// =============================================================================
// Publish Tests
// =============================================================================

func TestPublish_TypeMatching(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	var received int64
	bus.Subscribe(EventBan, func(e Event) {
		atomic.AddInt64(&received, 1)
	})

	// Publish matching event
	bus.Publish(NewEvent(EventBan, "test"))
	// Publish non-matching event
	bus.Publish(NewEvent(EventUnban, "test"))

	// Wait for async processing
	time.Sleep(50 * time.Millisecond)

	if atomic.LoadInt64(&received) != 1 {
		t.Errorf("expected 1 received event, got %d", atomic.LoadInt64(&received))
	}
}

func TestPublish_SubscribeAll(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	var received int64
	bus.SubscribeAll(func(e Event) {
		atomic.AddInt64(&received, 1)
	})

	// SubscribeAll should receive all event types
	bus.Publish(NewEvent(EventBan, "test"))
	bus.Publish(NewEvent(EventUnban, "test"))
	bus.Publish(NewEvent(EventLoginFail, "test"))

	time.Sleep(50 * time.Millisecond)

	if atomic.LoadInt64(&received) != 3 {
		t.Errorf("expected 3 received events, got %d", atomic.LoadInt64(&received))
	}
}

func TestPublish_MultipleSubscribers(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	var count1, count2 int64
	bus.Subscribe(EventBan, func(e Event) {
		atomic.AddInt64(&count1, 1)
	})
	bus.Subscribe(EventBan, func(e Event) {
		atomic.AddInt64(&count2, 1)
	})

	bus.Publish(NewEvent(EventBan, "test"))

	time.Sleep(50 * time.Millisecond)

	if atomic.LoadInt64(&count1) != 1 {
		t.Errorf("subscriber 1: expected 1 event, got %d", atomic.LoadInt64(&count1))
	}
	if atomic.LoadInt64(&count2) != 1 {
		t.Errorf("subscriber 2: expected 1 event, got %d", atomic.LoadInt64(&count2))
	}
}

func TestPublish_AutoSetsIDAndTimestamp(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	var receivedEvent Event
	var wg sync.WaitGroup
	wg.Add(1)
	bus.Subscribe(EventBan, func(e Event) {
		receivedEvent = e
		wg.Done()
	})

	// Publish event without ID or timestamp
	bus.Publish(Event{Type: EventBan})

	wg.Wait()

	if receivedEvent.ID == "" {
		t.Error("expected auto-generated ID")
	}
	if receivedEvent.Timestamp.IsZero() {
		t.Error("expected auto-set timestamp")
	}
}

func TestPublish_ClosedBus(t *testing.T) {
	bus := New()
	bus.Close()

	// Should not panic when publishing to closed bus
	bus.Publish(NewEvent(EventBan, "test"))
}

// =============================================================================
// PublishSync Tests
// =============================================================================

func TestPublishSync(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	received := false
	bus.Subscribe(EventBan, func(e Event) {
		received = true
	})

	bus.PublishSync(NewEvent(EventBan, "test"))

	// Should be synchronous - no need to wait
	if !received {
		t.Error("expected synchronous delivery")
	}
}

func TestPublishSync_ClosedBus(t *testing.T) {
	bus := New()
	bus.Close()

	// Should not panic when publishing sync to closed bus
	bus.PublishSync(NewEvent(EventBan, "test"))
}

func TestPublishSync_AutoSetsIDAndTimestamp(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	var receivedEvent Event
	bus.Subscribe(EventBan, func(e Event) {
		receivedEvent = e
	})

	bus.PublishSync(Event{Type: EventBan})

	if receivedEvent.ID == "" {
		t.Error("expected auto-generated ID")
	}
	if receivedEvent.Timestamp.IsZero() {
		t.Error("expected auto-set timestamp")
	}
}

// =============================================================================
// Panic Recovery Tests
// =============================================================================

func TestPublish_HandlerPanicRecovery(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	bus.Subscribe(EventBan, func(e Event) {
		panic("test panic")
	})

	// Should not crash
	bus.Publish(NewEvent(EventBan, "test"))

	time.Sleep(50 * time.Millisecond)

	stats := bus.Stats()
	if stats.Errors != 1 {
		t.Errorf("expected 1 error from panic, got %d", stats.Errors)
	}
}

func TestPublishSync_HandlerPanicRecovery(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	bus.Subscribe(EventBan, func(e Event) {
		panic("test panic")
	})

	// Should not crash
	bus.PublishSync(NewEvent(EventBan, "test"))

	stats := bus.Stats()
	if stats.Errors != 1 {
		t.Errorf("expected 1 error from panic, got %d", stats.Errors)
	}
}

// =============================================================================
// Close Tests
// =============================================================================

func TestClose(t *testing.T) {
	bus := NewWithConfig(4, 64)
	bus.Close()

	// Stats should still be queryable after close
	stats := bus.Stats()
	if stats.Workers != 4 {
		t.Errorf("expected 4 workers, got %d", stats.Workers)
	}
}

func TestClose_DoubleClose(t *testing.T) {
	bus := New()
	bus.Close()
	// Should not panic on double close
	bus.Close()
}

// =============================================================================
// Stats Tests
// =============================================================================

func TestStats_PublishMetrics(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	bus.Subscribe(EventBan, func(e Event) {})

	bus.Publish(NewEvent(EventBan, "test"))
	bus.Publish(NewEvent(EventBan, "test"))

	time.Sleep(50 * time.Millisecond)

	stats := bus.Stats()
	if stats.Published != 2 {
		t.Errorf("expected 2 published, got %d", stats.Published)
	}
	if stats.Delivered != 2 {
		t.Errorf("expected 2 delivered, got %d", stats.Delivered)
	}
}

// =============================================================================
// Backpressure Tests
// =============================================================================

func TestPublish_Backpressure(t *testing.T) {
	// Create a bus with very small queue
	bus := NewWithConfig(1, 1)
	defer bus.Close()

	// Subscribe with a slow handler to fill the queue
	bus.Subscribe(EventBan, func(e Event) {
		time.Sleep(100 * time.Millisecond)
	})

	// Rapidly publish many events - some should be dropped
	for i := 0; i < 50; i++ {
		bus.Publish(NewEvent(EventBan, "test"))
	}

	time.Sleep(200 * time.Millisecond)

	stats := bus.Stats()
	// At least some should have been dropped
	if stats.Published < 50 {
		t.Errorf("expected 50 published, got %d", stats.Published)
	}
	// Dropped + Delivered should equal Published (for matched subscriptions)
	total := stats.Delivered + stats.Dropped
	if total != stats.Published {
		t.Errorf("delivered(%d) + dropped(%d) = %d, want %d (published)",
			stats.Delivered, stats.Dropped, total, stats.Published)
	}
}

// =============================================================================
// Event Types Constants Tests
// =============================================================================

func TestEventTypes_Defined(t *testing.T) {
	// Verify all expected event types are defined and unique
	eventTypes := []EventType{
		EventBan, EventUnban,
		EventLoginFail, EventLoginFailed, EventLoginSuccess, EventLoginAlert,
		EventSuricataAlert, EventDDoSDetected, EventPortscan,
		EventFeedSync, EventFeedUpdate,
		EventHealthCheck, EventModuleStart, EventModuleStop, EventConfigReload, EventError,
		EventGeoIPUpdate, EventCountryBan,
	}

	seen := make(map[EventType]bool)
	for _, et := range eventTypes {
		if et == "" {
			t.Error("empty event type found")
		}
		// EventLoginFail and EventLoginFailed are aliases, skip uniqueness check for them
		if et != EventLoginFailed {
			if seen[et] {
				t.Errorf("duplicate event type: %q", et)
			}
		}
		seen[et] = true
	}
}

// =============================================================================
// Concurrency Tests
// =============================================================================

func TestBus_ConcurrentPublish(t *testing.T) {
	bus := NewWithConfig(8, 256)
	defer bus.Close()

	var received int64
	bus.Subscribe(EventBan, func(e Event) {
		atomic.AddInt64(&received, 1)
	})

	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			bus.Publish(NewEvent(EventBan, "test"))
		}()
	}
	wg.Wait()

	time.Sleep(100 * time.Millisecond)

	stats := bus.Stats()
	if stats.Published != 100 {
		t.Errorf("expected 100 published, got %d", stats.Published)
	}
}

func TestBus_ConcurrentSubscribeUnsubscribe(t *testing.T) {
	bus := NewWithConfig(4, 64)
	defer bus.Close()

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id := bus.Subscribe(EventBan, func(e Event) {})
			bus.Unsubscribe(id)
		}()
	}
	wg.Wait()

	// Should not deadlock or crash
}
