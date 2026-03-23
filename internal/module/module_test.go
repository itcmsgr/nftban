// =============================================================================
// NFTBan v1.0 - Module Interface Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for module registry, status methods, and error types"
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

package module

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
)

// =============================================================================
// Mock Module for Testing
// =============================================================================

type mockModule struct {
	name      string
	initErr   error
	startErr  error
	stopErr   error
	status    Status
	initCalls int
	startCalls int
	stopCalls  int
}

func (m *mockModule) Name() string { return m.name }
func (m *mockModule) Init(bus *eventbus.Bus) error {
	m.initCalls++
	return m.initErr
}
func (m *mockModule) Start(ctx context.Context) error {
	m.startCalls++
	return m.startErr
}
func (m *mockModule) Stop() error {
	m.stopCalls++
	return m.stopErr
}
func (m *mockModule) Status() Status {
	return m.status
}

// =============================================================================
// NewStatus Tests
// =============================================================================

func TestNewStatus(t *testing.T) {
	s := NewStatus("test-module")

	if s.Name != "test-module" {
		t.Errorf("expected name %q, got %q", "test-module", s.Name)
	}
	if !s.Enabled {
		t.Error("expected Enabled=true by default")
	}
	if !s.Healthy {
		t.Error("expected Healthy=true by default")
	}
	if s.Running {
		t.Error("expected Running=false by default")
	}
	if s.Extra == nil {
		t.Error("expected non-nil Extra map")
	}
}

// =============================================================================
// GetStatus Tests
// =============================================================================

func TestGetStatus_NilReceiver(t *testing.T) {
	var s *Status
	result := s.GetStatus()

	if result.Name != "unknown" {
		t.Errorf("expected name %q for nil receiver, got %q", "unknown", result.Name)
	}
	if result.Enabled {
		t.Error("expected Enabled=false for nil receiver")
	}
	if result.Running {
		t.Error("expected Running=false for nil receiver")
	}
	if result.Healthy {
		t.Error("expected Healthy=false for nil receiver")
	}
	if result.Extra == nil {
		t.Error("expected non-nil Extra map for nil receiver")
	}
}

func TestGetStatus_NonNil(t *testing.T) {
	s := NewStatus("test")
	s.Running = true

	result := s.GetStatus()
	if result.Name != "test" {
		t.Errorf("expected name %q, got %q", "test", result.Name)
	}
	if !result.Running {
		t.Error("expected Running=true")
	}
}

// =============================================================================
// Status Method Tests
// =============================================================================

func TestMarkRunning(t *testing.T) {
	s := NewStatus("test")
	s.MarkRunning()

	if !s.Running {
		t.Error("expected Running=true after MarkRunning")
	}
	if s.StartTime.IsZero() {
		t.Error("expected non-zero StartTime after MarkRunning")
	}
}

func TestMarkRunning_NilReceiver(t *testing.T) {
	var s *Status
	// Should not panic
	s.MarkRunning()
}

func TestMarkStopped(t *testing.T) {
	s := NewStatus("test")
	s.MarkRunning()
	s.MarkStopped()

	if s.Running {
		t.Error("expected Running=false after MarkStopped")
	}
}

func TestMarkStopped_NilReceiver(t *testing.T) {
	var s *Status
	// Should not panic
	s.MarkStopped()
}

func TestRecordError(t *testing.T) {
	s := NewStatus("test")
	err := errors.New("test error")
	s.RecordError(err)

	if s.ErrorCount != 1 {
		t.Errorf("expected ErrorCount=1, got %d", s.ErrorCount)
	}
	if s.LastError != "test error" {
		t.Errorf("expected LastError=%q, got %q", "test error", s.LastError)
	}
	if s.Healthy {
		t.Error("expected Healthy=false after error")
	}
}

func TestRecordError_Nil(t *testing.T) {
	s := NewStatus("test")
	s.RecordError(nil)

	// nil error should increment count but not set message
	if s.ErrorCount != 1 {
		t.Errorf("expected ErrorCount=1, got %d", s.ErrorCount)
	}
	if s.LastError != "" {
		t.Errorf("expected empty LastError for nil error, got %q", s.LastError)
	}
}

func TestRecordError_NilReceiver(t *testing.T) {
	var s *Status
	// Should not panic
	s.RecordError(errors.New("test"))
}

func TestRecordEvent(t *testing.T) {
	s := NewStatus("test")
	s.RecordEvent()
	s.RecordEvent()
	s.RecordEvent()

	if s.EventCount != 3 {
		t.Errorf("expected EventCount=3, got %d", s.EventCount)
	}
	if s.LastRun.IsZero() {
		t.Error("expected non-zero LastRun after RecordEvent")
	}
}

func TestRecordEvent_NilReceiver(t *testing.T) {
	var s *Status
	// Should not panic
	s.RecordEvent()
}

func TestClearError(t *testing.T) {
	s := NewStatus("test")
	s.RecordError(errors.New("test error"))
	s.ClearError()

	if s.LastError != "" {
		t.Errorf("expected empty LastError, got %q", s.LastError)
	}
	if !s.Healthy {
		t.Error("expected Healthy=true after ClearError")
	}
}

func TestClearError_NilReceiver(t *testing.T) {
	var s *Status
	// Should not panic
	s.ClearError()
}

func TestUpdateUptime_NotRunning(t *testing.T) {
	s := NewStatus("test")
	s.UpdateUptime()

	if s.Uptime != "-" {
		t.Errorf("expected Uptime=%q for non-running module, got %q", "-", s.Uptime)
	}
}

func TestUpdateUptime_ZeroStartTime(t *testing.T) {
	s := NewStatus("test")
	s.Running = true
	// StartTime is zero
	s.UpdateUptime()

	if s.Uptime != "-" {
		t.Errorf("expected Uptime=%q for zero start time, got %q", "-", s.Uptime)
	}
}

func TestUpdateUptime_NilReceiver(t *testing.T) {
	var s *Status
	// Should not panic
	s.UpdateUptime()
}

func TestUpdateUptime_Running(t *testing.T) {
	s := NewStatus("test")
	s.Running = true
	s.StartTime = time.Now().Add(-5 * time.Second)
	s.UpdateUptime()

	if s.Uptime == "-" || s.Uptime == "" {
		t.Errorf("expected non-empty uptime for running module, got %q", s.Uptime)
	}
}

// =============================================================================
// formatDuration Tests
// =============================================================================

func TestFormatDuration(t *testing.T) {
	tests := []struct {
		name     string
		duration time.Duration
		want     string
	}{
		{"seconds", 30 * time.Second, "30s"},
		{"one_minute", 1 * time.Minute, "1m0s"},
		{"minutes", 5*time.Minute + 30*time.Second, "6m0s"}, // Rounded to minute
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatDuration(tt.duration)
			if got != tt.want {
				t.Errorf("formatDuration(%v) = %q, want %q", tt.duration, got, tt.want)
			}
		})
	}
}

func TestFormatDuration_Hours(t *testing.T) {
	d := 2*time.Hour + 30*time.Minute
	result := formatDuration(d)
	// Should contain "hour" and "min" keywords
	if result == "" {
		t.Error("expected non-empty result for hours")
	}
}

func TestFormatDuration_Days(t *testing.T) {
	d := 3*24*time.Hour + 5*time.Hour
	result := formatDuration(d)
	// Should contain "day" and "hour" keywords
	if result == "" {
		t.Error("expected non-empty result for days")
	}
}

// =============================================================================
// Registry Tests
// =============================================================================

func TestNewRegistry(t *testing.T) {
	r := NewRegistry()
	if r == nil {
		t.Fatal("expected non-nil Registry")
	}
	if len(r.Names()) != 0 {
		t.Errorf("expected empty registry, got %d modules", len(r.Names()))
	}
}

func TestRegistry_Register(t *testing.T) {
	r := NewRegistry()
	m := &mockModule{name: "test-module"}
	d := Descriptor{Name: "test-module", Version: "1.0.0"}

	r.Register(m, d)

	names := r.Names()
	if len(names) != 1 {
		t.Errorf("expected 1 module, got %d", len(names))
	}
}

func TestRegistry_Get(t *testing.T) {
	r := NewRegistry()
	m := &mockModule{name: "test-module"}
	r.Register(m, Descriptor{Name: "test-module"})

	got, ok := r.Get("test-module")
	if !ok {
		t.Error("expected to find module")
	}
	if got.Name() != "test-module" {
		t.Errorf("expected module name %q, got %q", "test-module", got.Name())
	}
}

func TestRegistry_Get_NotFound(t *testing.T) {
	r := NewRegistry()
	_, ok := r.Get("nonexistent")
	if ok {
		t.Error("expected module not found")
	}
}

func TestRegistry_GetDescriptor(t *testing.T) {
	r := NewRegistry()
	m := &mockModule{name: "test-module"}
	desc := Descriptor{
		Name:        "test-module",
		Version:     "1.0.0",
		Description: "A test module",
		Optional:    true,
	}
	r.Register(m, desc)

	got, ok := r.GetDescriptor("test-module")
	if !ok {
		t.Error("expected to find descriptor")
	}
	if got.Version != "1.0.0" {
		t.Errorf("expected version %q, got %q", "1.0.0", got.Version)
	}
	if got.Description != "A test module" {
		t.Errorf("expected description %q, got %q", "A test module", got.Description)
	}
	if !got.Optional {
		t.Error("expected Optional=true")
	}
}

func TestRegistry_GetDescriptor_NotFound(t *testing.T) {
	r := NewRegistry()
	_, ok := r.GetDescriptor("nonexistent")
	if ok {
		t.Error("expected descriptor not found")
	}
}

func TestRegistry_All(t *testing.T) {
	r := NewRegistry()
	r.Register(&mockModule{name: "mod1"}, Descriptor{Name: "mod1"})
	r.Register(&mockModule{name: "mod2"}, Descriptor{Name: "mod2"})

	all := r.All()
	if len(all) != 2 {
		t.Errorf("expected 2 modules, got %d", len(all))
	}
}

func TestRegistry_Names(t *testing.T) {
	r := NewRegistry()
	r.Register(&mockModule{name: "alpha"}, Descriptor{Name: "alpha"})
	r.Register(&mockModule{name: "beta"}, Descriptor{Name: "beta"})

	names := r.Names()
	if len(names) != 2 {
		t.Errorf("expected 2 names, got %d", len(names))
	}

	// Should contain both names (order not guaranteed)
	nameSet := make(map[string]bool)
	for _, n := range names {
		nameSet[n] = true
	}
	if !nameSet["alpha"] || !nameSet["beta"] {
		t.Errorf("expected names alpha and beta, got %v", names)
	}
}

// =============================================================================
// Registry Lifecycle Tests
// =============================================================================

func TestRegistry_InitAll(t *testing.T) {
	r := NewRegistry()
	m1 := &mockModule{name: "mod1"}
	m2 := &mockModule{name: "mod2"}
	r.Register(m1, Descriptor{Name: "mod1"})
	r.Register(m2, Descriptor{Name: "mod2"})

	bus := eventbus.New()
	defer bus.Close()

	err := r.InitAll(bus)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m1.initCalls != 1 {
		t.Errorf("expected 1 init call for mod1, got %d", m1.initCalls)
	}
	if m2.initCalls != 1 {
		t.Errorf("expected 1 init call for mod2, got %d", m2.initCalls)
	}
}

func TestRegistry_InitAll_Error(t *testing.T) {
	r := NewRegistry()
	m := &mockModule{name: "failing", initErr: errors.New("init failed")}
	r.Register(m, Descriptor{Name: "failing"})

	bus := eventbus.New()
	defer bus.Close()

	err := r.InitAll(bus)
	if err == nil {
		t.Error("expected error from InitAll")
	}

	var moduleErr *ModuleError
	if !errors.As(err, &moduleErr) {
		t.Error("expected ModuleError type")
	}
}

func TestRegistry_StartAll(t *testing.T) {
	r := NewRegistry()
	m := &mockModule{name: "mod1"}
	r.Register(m, Descriptor{Name: "mod1"})

	ctx := context.Background()
	err := r.StartAll(ctx)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m.startCalls != 1 {
		t.Errorf("expected 1 start call, got %d", m.startCalls)
	}
}

func TestRegistry_StartAll_Error(t *testing.T) {
	r := NewRegistry()
	m := &mockModule{name: "failing", startErr: errors.New("start failed")}
	r.Register(m, Descriptor{Name: "failing"})

	ctx := context.Background()
	err := r.StartAll(ctx)
	if err == nil {
		t.Error("expected error from StartAll")
	}
}

func TestRegistry_StopAll(t *testing.T) {
	r := NewRegistry()
	m1 := &mockModule{name: "mod1"}
	m2 := &mockModule{name: "mod2"}
	r.Register(m1, Descriptor{Name: "mod1"})
	r.Register(m2, Descriptor{Name: "mod2"})

	err := r.StopAll()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m1.stopCalls != 1 {
		t.Errorf("expected 1 stop call for mod1, got %d", m1.stopCalls)
	}
	if m2.stopCalls != 1 {
		t.Errorf("expected 1 stop call for mod2, got %d", m2.stopCalls)
	}
}

func TestRegistry_StopAll_Error(t *testing.T) {
	r := NewRegistry()
	m := &mockModule{name: "failing", stopErr: errors.New("stop failed")}
	r.Register(m, Descriptor{Name: "failing"})

	err := r.StopAll()
	if err == nil {
		t.Error("expected error from StopAll")
	}
}

func TestRegistry_StatusAll(t *testing.T) {
	r := NewRegistry()
	m1 := &mockModule{name: "mod1", status: NewStatus("mod1")}
	m2 := &mockModule{name: "mod2", status: NewStatus("mod2")}
	m1.status.Running = true
	r.Register(m1, Descriptor{Name: "mod1"})
	r.Register(m2, Descriptor{Name: "mod2"})

	statuses := r.StatusAll()
	if len(statuses) != 2 {
		t.Errorf("expected 2 statuses, got %d", len(statuses))
	}
	if !statuses["mod1"].Running {
		t.Error("expected mod1 Running=true")
	}
	if statuses["mod2"].Running {
		t.Error("expected mod2 Running=false")
	}
}

// =============================================================================
// ModuleError Tests
// =============================================================================

func TestModuleError_Error(t *testing.T) {
	inner := errors.New("connection refused")
	err := &ModuleError{
		Module: "suricata",
		Op:     "start",
		Err:    inner,
	}

	expected := "module suricata start: connection refused"
	if err.Error() != expected {
		t.Errorf("expected %q, got %q", expected, err.Error())
	}
}

func TestModuleError_Unwrap(t *testing.T) {
	inner := errors.New("test error")
	err := &ModuleError{
		Module: "test",
		Op:     "init",
		Err:    inner,
	}

	if !errors.Is(err, inner) {
		t.Error("expected Unwrap to return inner error")
	}
}
