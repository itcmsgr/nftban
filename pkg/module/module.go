// =============================================================================
// NFTBan v1.0 - Module Interface
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2024-12-01"
// meta:description="Defines the interface all nftban modules must implement"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Package: module
// Purpose: Defines the interface all nftban modules must implement
//
// Architecture:
// - Each module is a self-contained unit
// - Modules communicate via the event bus
// - Modules have lifecycle: Init → Start → Stop
// - Modules report their status on demand
//
// Example implementation:
//
//	type MyModule struct {
//	    bus    *eventbus.Bus
//	    cancel context.CancelFunc
//	}
//
//	func (m *MyModule) Name() string { return "my-module" }
//	func (m *MyModule) Init(bus *eventbus.Bus) error { m.bus = bus; return nil }
//	func (m *MyModule) Start(ctx context.Context) error { ... }
//	func (m *MyModule) Stop() error { m.cancel(); return nil }
//	func (m *MyModule) Status() module.Status { ... }
//
// =============================================================================

package module

import (
	"context"
	"time"

	"github.com/itcmsgr/nftban/pkg/eventbus"
)

// Module is the interface all nftban modules must implement
type Module interface {
	// Name returns the unique module identifier
	// Examples: "login-monitor", "suricata-watcher", "feeds-sync"
	Name() string

	// Init initializes the module with the event bus
	// Called once before Start
	// Should set up internal state but NOT start background work
	Init(bus *eventbus.Bus) error

	// Start begins the module's background work
	// Called after Init
	// Should spawn goroutines for continuous work
	// The context is cancelled when the daemon shuts down
	Start(ctx context.Context) error

	// Stop gracefully shuts down the module
	// Called when daemon is stopping
	// Should clean up resources and wait for goroutines to finish
	Stop() error

	// Status returns the current module status
	// Called on demand for health checks and API responses
	Status() Status
}

// Status contains runtime status information for a module
type Status struct {
	Name        string    `json:"name"`         // Module name
	Enabled     bool      `json:"enabled"`      // Whether module is enabled in config
	Running     bool      `json:"running"`      // Whether module is currently running
	Healthy     bool      `json:"healthy"`      // Whether module is functioning correctly
	LastRun     time.Time `json:"last_run"`     // Last time module performed its main task
	LastError   string    `json:"last_error"`   // Last error message (empty if none)
	ErrorCount  int       `json:"error_count"`  // Total errors since start
	EventCount  int64     `json:"event_count"`  // Total events processed
	StartTime   time.Time `json:"start_time"`   // When module was started
	Uptime      string    `json:"uptime"`       // Human-readable uptime
	Extra       ExtraInfo `json:"extra"`        // Module-specific status info
}

// ExtraInfo holds module-specific status information
type ExtraInfo map[string]any

// NewStatus creates a new Status with defaults
func NewStatus(name string) Status {
	return Status{
		Name:    name,
		Enabled: true,
		Healthy: true,
		Extra:   make(ExtraInfo),
	}
}

// GetStatus safely returns a Status, handling nil receiver.
// If the status pointer is nil, returns a default "unknown" status.
func (s *Status) GetStatus() Status {
	if s == nil {
		return Status{
			Name:    "unknown",
			Enabled: false,
			Running: false,
			Healthy: false,
			Extra:   make(ExtraInfo),
		}
	}
	return *s
}

// MarkRunning updates status to indicate module is running
func (s *Status) MarkRunning() {
	if s == nil {
		return
	}
	s.Running = true
	s.StartTime = time.Now()
}

// MarkStopped updates status to indicate module is stopped
func (s *Status) MarkStopped() {
	if s == nil {
		return
	}
	s.Running = false
}

// RecordError records an error
func (s *Status) RecordError(err error) {
	if s == nil {
		return
	}
	s.ErrorCount++
	if err != nil {
		s.LastError = err.Error()
		s.Healthy = false
	}
}

// RecordEvent increments the event counter
func (s *Status) RecordEvent() {
	if s == nil {
		return
	}
	s.EventCount++
	s.LastRun = time.Now()
}

// ClearError clears the last error
func (s *Status) ClearError() {
	if s == nil {
		return
	}
	s.LastError = ""
	s.Healthy = true
}

// UpdateUptime calculates and updates the uptime string
func (s *Status) UpdateUptime() {
	if s == nil {
		return
	}
	if s.StartTime.IsZero() || !s.Running {
		s.Uptime = "-"
		return
	}
	d := time.Since(s.StartTime)
	s.Uptime = formatDuration(d)
}

// formatDuration creates a human-readable duration string
func formatDuration(d time.Duration) string {
	if d < time.Minute {
		return d.Round(time.Second).String()
	}
	if d < time.Hour {
		return d.Round(time.Minute).String()
	}
	if d < 24*time.Hour {
		h := d / time.Hour
		m := (d % time.Hour) / time.Minute
		return formatPlural(int(h), "hour") + " " + formatPlural(int(m), "min")
	}
	days := d / (24 * time.Hour)
	hours := (d % (24 * time.Hour)) / time.Hour
	return formatPlural(int(days), "day") + " " + formatPlural(int(hours), "hour")
}

func formatPlural(n int, unit string) string {
	if n == 1 {
		return "1 " + unit
	}
	return string(rune('0'+n%10)) + string(rune('0'+n/10%10))[1:] + " " + unit + "s"
}

// Descriptor contains static metadata about a module
type Descriptor struct {
	Name         string   `json:"name"`          // Unique module identifier
	Version      string   `json:"version"`       // Module version
	Description  string   `json:"description"`   // Human-readable description
	Dependencies []string `json:"dependencies"`  // Other modules this depends on
	Optional     bool     `json:"optional"`      // Whether module can be disabled
	ConfigFile   string   `json:"config_file"`   // Path to module's config file
}

// Registry manages all registered modules
type Registry struct {
	modules     map[string]Module
	descriptors map[string]Descriptor
}

// NewRegistry creates a new module registry
func NewRegistry() *Registry {
	return &Registry{
		modules:     make(map[string]Module),
		descriptors: make(map[string]Descriptor),
	}
}

// Register adds a module to the registry
func (r *Registry) Register(m Module, d Descriptor) {
	name := m.Name()
	r.modules[name] = m
	r.descriptors[name] = d
}

// Get retrieves a module by name
func (r *Registry) Get(name string) (Module, bool) {
	m, ok := r.modules[name]
	return m, ok
}

// GetDescriptor retrieves a module descriptor by name
func (r *Registry) GetDescriptor(name string) (Descriptor, bool) {
	d, ok := r.descriptors[name]
	return d, ok
}

// All returns all registered modules
func (r *Registry) All() map[string]Module {
	return r.modules
}

// Names returns all registered module names
func (r *Registry) Names() []string {
	names := make([]string, 0, len(r.modules))
	for name := range r.modules {
		names = append(names, name)
	}
	return names
}

// InitAll initializes all modules with the event bus
func (r *Registry) InitAll(bus *eventbus.Bus) error {
	for name, m := range r.modules {
		if err := m.Init(bus); err != nil {
			return &ModuleError{Module: name, Op: "init", Err: err}
		}
	}
	return nil
}

// StartAll starts all modules
func (r *Registry) StartAll(ctx context.Context) error {
	for name, m := range r.modules {
		if err := m.Start(ctx); err != nil {
			return &ModuleError{Module: name, Op: "start", Err: err}
		}
	}
	return nil
}

// StopAll stops all modules
func (r *Registry) StopAll() error {
	var lastErr error
	for name, m := range r.modules {
		if err := m.Stop(); err != nil {
			lastErr = &ModuleError{Module: name, Op: "stop", Err: err}
		}
	}
	return lastErr
}

// StatusAll returns status for all modules
func (r *Registry) StatusAll() map[string]Status {
	statuses := make(map[string]Status, len(r.modules))
	for name, m := range r.modules {
		statuses[name] = m.Status()
	}
	return statuses
}

// ModuleError wraps errors with module context
type ModuleError struct {
	Module string
	Op     string
	Err    error
}

func (e *ModuleError) Error() string {
	return "module " + e.Module + " " + e.Op + ": " + e.Err.Error()
}

func (e *ModuleError) Unwrap() error {
	return e.Err
}
