// =============================================================================
// NFTBan v1.0 - Port Scan Detection Module (Go Wrapper)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: portscan
// Purpose: Go module wrapper for portscan detection, integrates with event bus
//
// Architecture:
// - Wraps the bash dual-mode implementation (classic/suricata/hybrid)
// - Publishes events to the central event bus
// - Subscribes to portscan events from other modules
// - Runs periodic detection cycles via goroutine
//
// The bash scripts remain the implementation layer, this module provides:
// - Event bus integration
// - Daemon lifecycle management
// - Metrics collection
// =============================================================================

package portscan

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
	ModuleName    = "portscan"
	ModuleVersion = "1.0.0"

	// Check interval
	DefaultCheckInterval = 60 * time.Second
)

// getPortscanScript returns the portscan script path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getPortscanScript() string {
	cfg := nftbanconf.MustLoad()
	return cfg.LibDir + "/core/nftban_portscan.sh"
}

// Module implements the portscan detection module
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
	scansDetected int64
}

// New creates a new portscan detection module
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
	bus.Subscribe(eventbus.EventPortscan, m.handlePortscanEvent)

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

	// Enable portscan detection
	if err := m.enable(); err != nil {
		m.status.RecordError(err)
	}

	// Start periodic detection goroutine
	go m.runDetectionCycle(ctx)

	// Publish module start event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStart, ModuleName).
		WithMessage("Portscan detection module started").
		WithData("mode", m.mode))

	return nil
}

// Stop gracefully shuts down the module
func (m *Module) Stop() error {
	if m.cancel != nil {
		m.cancel()
	}

	// Disable portscan detection
	m.disable()

	m.mu.Lock()
	m.status.MarkStopped()
	m.mu.Unlock()

	// Publish module stop event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, ModuleName).
		WithMessage("Portscan detection module stopped"))

	return nil
}

// Status returns the current module status
func (m *Module) Status() module.Status {
	m.mu.RLock()
	defer m.mu.RUnlock()

	m.status.UpdateUptime()
	m.status.Extra["mode"] = m.mode
	m.status.Extra["suricata_available"] = m.suricataAvail
	m.status.Extra["scans_detected"] = m.scansDetected

	return m.status
}

// detectMode detects the current portscan detection mode
func (m *Module) detectMode() {
	scriptPath := getPortscanScript()
	// Source the script and get mode
	out, err := exec.Command("bash", "-c",
		"source "+scriptPath+" 2>/dev/null && nftban_portscan_load_config && _nftban_portscan_detect_mode").Output()
	if err != nil {
		m.mode = "classic" // Default fallback
		return
	}
	m.mode = strings.TrimSpace(string(out))

	// Check Suricata availability
	out, _ = exec.Command("bash", "-c",
		"source "+scriptPath+" 2>/dev/null && _nftban_portscan_suricata_is_available && echo yes || echo no").Output()
	m.suricataAvail = strings.TrimSpace(string(out)) == "yes"
}

// enable enables portscan detection
func (m *Module) enable() error {
	cmd := exec.Command("bash", "-c", "source "+getPortscanScript()+" && nftban_portscan_enable")
	return cmd.Run()
}

// disable disables portscan detection
func (m *Module) disable() error {
	cmd := exec.Command("bash", "-c", "source "+getPortscanScript()+" && nftban_portscan_disable")
	return cmd.Run()
}

// runDetectionCycle runs periodic detection cycles
func (m *Module) runDetectionCycle(ctx context.Context) {
	ticker := time.NewTicker(m.checkInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.runCycle()
		}
	}
}

// runCycle runs a single detection cycle
func (m *Module) runCycle() {
	// Run the bash detection script
	cmd := exec.Command("bash", "-c", "source "+getPortscanScript()+" && nftban_portscan_run")
	err := cmd.Run()

	m.mu.Lock()
	defer m.mu.Unlock()

	m.status.RecordEvent()
	if err != nil {
		m.status.RecordError(err)
	} else {
		m.status.ClearError()
	}
}

// handlePortscanEvent handles portscan events from other sources
func (m *Module) handlePortscanEvent(e eventbus.Event) {
	m.mu.Lock()
	m.scansDetected++
	m.status.RecordEvent()
	m.mu.Unlock()

	// Publish processed event
	if m.bus != nil {
		m.bus.Publish(eventbus.NewEvent(eventbus.EventPortscan, ModuleName).
			WithIP(e.IP).
			WithMessage("Portscan detected and processed").
			WithSeverity(eventbus.SeverityWarning).
			WithData("total_scans", m.scansDetected))
	}
}

// Descriptor returns the module descriptor
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func Descriptor() module.Descriptor {
	cfg := nftbanconf.MustLoad()
	return module.Descriptor{
		Name:        ModuleName,
		Version:     ModuleVersion,
		Description: "Port Scan Detection (Dual-Mode: Classic/Suricata/Hybrid)",
		Optional:    false,
		ConfigFile:  cfg.ConfigDir + "/conf.d/portscan/main.conf",
	}
}
