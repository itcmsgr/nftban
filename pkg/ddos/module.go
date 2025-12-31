// =============================================================================
// NFTBan v1.0 - DDoS Protection Module (Go Wrapper)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: ddos
// Purpose: Go module wrapper for DDoS protection, integrates with event bus
//
// Architecture:
// - Wraps the bash dual-mode implementation (classic/suricata/hybrid)
// - Publishes events to the central event bus
// - Subscribes to ban events from other modules
// - Runs periodic checks via goroutine
//
// The bash scripts remain the implementation layer, this module provides:
// - Event bus integration
// - Daemon lifecycle management
// - Metrics collection
// =============================================================================

package ddos

import (
	"context"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/module"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

const (
	ModuleName    = "ddos"
	ModuleVersion = "1.0.0"

	// Check interval
	DefaultCheckInterval = 30 * time.Second
)

// getDDOSScript returns the DDoS script path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getDDOSScript() string {
	cfg := nftbanconf.MustLoad()
	return cfg.LibDir + "/core/nftban_ddos.sh"
}

// Module implements the DDoS protection module
type Module struct {
	bus           *eventbus.Bus
	status        module.Status
	mu            sync.RWMutex
	cancel        context.CancelFunc
	checkInterval time.Duration

	// Runtime state
	mode          string // classic, suricata, hybrid, auto
	enabled       bool
	suricataAvail bool
}

// New creates a new DDoS protection module
func New() *Module {
	return &Module{
		status:        module.NewStatus(ModuleName),
		checkInterval: DefaultCheckInterval,
		mode:          "auto",
		enabled:       true,
	}
}

// Name returns the module identifier
func (m *Module) Name() string {
	return ModuleName
}

// Init initializes the module with the event bus
func (m *Module) Init(bus *eventbus.Bus) error {
	m.bus = bus

	// Subscribe to relevant events
	bus.Subscribe(eventbus.EventDDoSDetected, m.handleDDoSEvent)

	// Detect current mode
	m.detectMode()

	m.status.Enabled = m.enabled
	return nil
}

// Start begins the module's background work
func (m *Module) Start(ctx context.Context) error {
	ctx, m.cancel = context.WithCancel(ctx)

	m.mu.Lock()
	m.status.MarkRunning()
	m.mu.Unlock()

	// Enable DDoS protection
	if err := m.enable(); err != nil {
		m.status.RecordError(err)
		// Don't fail start, just log
	}

	// Start periodic check goroutine
	go m.runPeriodicCheck(ctx)

	// Publish module start event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStart, ModuleName).
		WithMessage("DDoS protection module started").
		WithData("mode", m.mode))

	return nil
}

// Stop gracefully shuts down the module
func (m *Module) Stop() error {
	if m.cancel != nil {
		m.cancel()
	}

	// Disable DDoS protection
	m.disable()

	m.mu.Lock()
	m.status.MarkStopped()
	m.mu.Unlock()

	// Publish module stop event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, ModuleName).
		WithMessage("DDoS protection module stopped"))

	return nil
}

// Status returns the current module status
func (m *Module) Status() module.Status {
	m.mu.RLock()
	defer m.mu.RUnlock()

	m.status.UpdateUptime()
	m.status.Extra["mode"] = m.mode
	m.status.Extra["suricata_available"] = m.suricataAvail

	return m.status
}

// detectMode detects the current DDoS protection mode
func (m *Module) detectMode() {
	scriptPath := getDDOSScript()
	out, err := exec.Command("bash", "-c", "source "+scriptPath+" && nftban_ddos_get_mode").Output()
	if err != nil {
		m.mode = "classic" // Default fallback
		return
	}
	m.mode = strings.TrimSpace(string(out))

	// Check Suricata availability
	out, _ = exec.Command("bash", "-c", "source "+scriptPath+" && nftban_ddos_suricata_available && echo yes || echo no").Output()
	m.suricataAvail = strings.TrimSpace(string(out)) == "yes"
}

// enable enables DDoS protection
func (m *Module) enable() error {
	cmd := exec.Command("bash", "-c", "source "+getDDOSScript()+" && nftban_ddos_enable")
	return cmd.Run()
}

// disable disables DDoS protection
func (m *Module) disable() error {
	cmd := exec.Command("bash", "-c", "source "+getDDOSScript()+" && nftban_ddos_disable")
	return cmd.Run()
}

// runPeriodicCheck runs periodic status checks
func (m *Module) runPeriodicCheck(ctx context.Context) {
	ticker := time.NewTicker(m.checkInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.checkStatus()
		}
	}
}

// checkStatus checks current DDoS status and updates metrics
func (m *Module) checkStatus() {
	m.detectMode()

	m.mu.Lock()
	m.status.RecordEvent()
	m.status.ClearError()
	m.mu.Unlock()
}

// handleDDoSEvent handles DDoS detection events from other sources
func (m *Module) handleDDoSEvent(e eventbus.Event) {
	m.mu.Lock()
	m.status.RecordEvent()
	m.mu.Unlock()

	// Log the event
	if m.bus != nil {
		m.bus.Publish(eventbus.NewEvent(eventbus.EventDDoSDetected, ModuleName).
			WithIP(e.IP).
			WithMessage("DDoS event processed").
			WithSeverity(eventbus.SeverityWarning))
	}
}

// Descriptor returns the module descriptor
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func Descriptor() module.Descriptor {
	cfg := nftbanconf.MustLoad()
	return module.Descriptor{
		Name:        ModuleName,
		Version:     ModuleVersion,
		Description: "DDoS Protection (Dual-Mode: Classic/Suricata/Hybrid)",
		Optional:    false,
		ConfigFile:  cfg.ConfigDir + "/conf.d/ddos/main.conf",
	}
}
