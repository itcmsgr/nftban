// =============================================================================
// NFTBan v1.20.0 - HTTP Bot Guard: Main Controller
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Classification loop and module interface for HTTP bot detection
//
// meta:name="botguard_guard"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="Main controller for kernel-native HTTP bot detection"
//
// Architecture — Three Clocks:
//   Clock 1 (Kernel):  nft meter marks suspects per-packet → http_bot_suspect set
//   Clock 2 (Go):      This module — 60s/40s loop reads suspects, classifies, enforces
//   Clock 3 (Shell):   Botscan batch — 10min pattern matching → batch_signals.jsonl
//
// Principle: Kernel DETECTS, Go DECIDES, Kernel ENFORCES
//
// meta:inventory.files="guard.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/botguard/main.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"context"
	"fmt"
	"log"
	"net/netip"
	"path/filepath"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/module"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/opqueue"
)

const (
	ModuleName    = "botguard"
	ModuleVersion = "1.0.0"
)

// getBotguardPaths returns paths from central config.
func getBotguardPaths() (configDir, dataDir, logFile string) {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir + "/conf.d/botguard",
		cfg.DataDir + "/botguard",
		cfg.LogDir + "/botguard.log"
}

// Module implements the bot guard module (module.Module interface).
type Module struct {
	bus    *eventbus.Bus
	status module.Status
	mu     sync.RWMutex
	cancel context.CancelFunc

	// Configuration
	config *Config

	// Components
	reader   *SuspectReader
	enforcer *Enforcer

	// State map: tracked IPs and their classification
	ips   map[netip.Addr]*IPRecord
	ipsMu sync.RWMutex

	// Statistics
	stats GuardStats
}

// New creates a new bot guard module.
func New() *Module {
	return &Module{
		status: module.NewStatus(ModuleName),
		config: DefaultConfig(),
		reader: NewSuspectReader(),
		ips:    make(map[netip.Addr]*IPRecord),
	}
}

// Descriptor returns the module descriptor for registration.
func Descriptor() module.Descriptor {
	configDir, _, _ := getBotguardPaths()
	return module.Descriptor{
		Name:        ModuleName,
		Version:     ModuleVersion,
		Description: "HTTP Bot Guard: Intelligent Crawler Detection & Protection",
		Optional:    true,
		ConfigFile:  filepath.Join(configDir, "main.conf"),
	}
}

// Name returns the module identifier.
func (m *Module) Name() string {
	return ModuleName
}

// Init initializes the module with the event bus.
func (m *Module) Init(bus *eventbus.Bus) error {
	m.bus = bus

	// Load configuration
	configDir, _, _ := getBotguardPaths()
	cfg, err := LoadConfig(filepath.Join(configDir, "main.conf"))
	if err != nil {
		return fmt.Errorf("load botguard config: %w", err)
	}
	m.config = cfg
	m.status.Enabled = cfg.Enabled

	return nil
}

// InitEnforcer sets up the enforcer with the OpQueue.
// Called after daemon creates the OpQueue.
func (m *Module) InitEnforcer(queue *opqueue.OpQueue) {
	m.enforcer = NewEnforcer(queue, m.config)
}

// Start begins the classification loop.
func (m *Module) Start(ctx context.Context) error {
	if !m.config.Enabled {
		log.Printf("[botguard] Module disabled in config")
		return nil
	}

	if m.enforcer == nil {
		return fmt.Errorf("enforcer not initialized — call InitEnforcer before Start")
	}

	ctx, m.cancel = context.WithCancel(ctx)

	m.mu.Lock()
	m.status.MarkRunning()
	m.mu.Unlock()

	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStart, ModuleName).
		WithMessage("HTTP Bot Guard started — kernel suspect marking active").
		WithData("loop_interval", m.config.LoopInterval.String()).
		WithData("pressure_interval", m.config.LoopPressureInterval.String()))

	// Start the classification loop
	go m.runClassificationLoop(ctx)

	// Start the cleanup loop (prune expired records)
	go m.runCleanup(ctx)

	return nil
}

// Stop gracefully shuts down the module.
func (m *Module) Stop() error {
	if m.cancel != nil {
		m.cancel()
	}

	m.mu.Lock()
	m.status.MarkStopped()
	m.mu.Unlock()

	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, ModuleName).
		WithMessage("HTTP Bot Guard stopped").
		WithData("total_ticks", m.stats.TickCount).
		WithData("total_classified", m.stats.Classified).
		WithData("total_bans", m.stats.BanCount))

	return nil
}

// Status returns the current module status.
func (m *Module) Status() module.Status {
	m.mu.RLock()
	defer m.mu.RUnlock()

	m.status.UpdateUptime()
	m.status.Extra["loop_interval"] = m.config.LoopInterval.String()
	m.status.Extra["pressure_mode"] = m.stats.PressureMode
	m.status.Extra["tracked_ips"] = m.stats.TrackedIPs
	m.status.Extra["total_ticks"] = m.stats.TickCount
	m.status.Extra["suspects_found"] = m.stats.SuspectsFound
	m.status.Extra["classified"] = m.stats.Classified
	m.status.Extra["allow_count"] = m.stats.AllowCount
	m.status.Extra["grey_count"] = m.stats.GreyCount
	m.status.Extra["ban_count"] = m.stats.BanCount
	m.status.Extra["emergency_count"] = m.stats.EmergencyCount
	m.status.Extra["last_tick_duration"] = m.stats.LastTickDuration.String()

	return m.status
}

// runClassificationLoop is the main Clock 2 loop.
// Runs every 60s (normal) or 40s (under pressure).
func (m *Module) runClassificationLoop(ctx context.Context) {
	ticker := time.NewTicker(m.config.LoopInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			start := time.Now()
			m.tick(ctx)
			duration := time.Since(start)

			m.mu.Lock()
			m.stats.TickCount++
			m.stats.LastTickDuration = duration
			m.stats.LastTickTime = time.Now()
			m.status.RecordEvent()
			m.status.ClearError()
			m.mu.Unlock()
		}
	}
}

// tick performs one classification cycle:
// 1. Read kernel suspect set (20-100 IPs, microseconds)
// 2. For each new suspect, create pending record
// 3. Classify pending IPs (Phase 1: basic threshold, Phase 2+: FCrDNS)
// 4. Write decisions to enforcement sets via OpQueue
func (m *Module) tick(ctx context.Context) {
	// Step 1: Read kernel suspect set
	suspects, err := m.reader.ReadSuspects(ctx)
	if err != nil {
		log.Printf("[botguard] suspect read error: %v", err)
		m.mu.Lock()
		m.status.RecordError(err)
		m.mu.Unlock()
		return
	}

	m.mu.Lock()
	m.stats.SuspectsFound += int64(len(suspects))
	m.mu.Unlock()

	// Step 2: Process each suspect
	for _, ip := range suspects {
		record := m.getOrCreate(ip)

		// Update last seen
		record.LastSeen = time.Now()
		record.HitCount++

		// Step 3: Classify if not already classified
		if record.State == StateUnknown || record.State == StatePending {
			m.classify(record)
		}
	}

	// Update tracked IP count
	m.ipsMu.RLock()
	m.mu.Lock()
	m.stats.TrackedIPs = int64(len(m.ips))
	m.mu.Unlock()
	m.ipsMu.RUnlock()
}

// classify determines the classification for an IP.
// Phase 1: Basic threshold-based classification.
// Phase 2+ will add FCrDNS verification and bot config lookup.
func (m *Module) classify(r *IPRecord) {
	oldState := r.State

	// Phase 1 classification: threshold-based
	// IPs in the suspect set already exceeded kernel rate threshold.
	// For Phase 1, we classify based on hit count pattern:
	//   - First time seen → pending (light throttle while we gather data)
	//   - Seen multiple ticks → grey (sustained abuse → penalty ladder)
	//   - Seen many ticks or high hit count → ban
	switch {
	case r.HitCount >= 10:
		// Persistent offender across many ticks → ban
		r.State = StateBan
		r.Reasons = append(r.Reasons, "persistent_suspect")
		r.ExpiresAt = time.Now().Add(m.config.BanTTL)
	case r.HitCount >= 3:
		// Repeated suspect → grey (penalty ladder throttle)
		r.State = StateGrey
		r.Reasons = append(r.Reasons, "repeated_suspect")
		r.ExpiresAt = time.Now().Add(m.config.GreyTTL)
	default:
		// First detection → pending (gather more data)
		if r.State == StateUnknown {
			r.State = StatePending
			r.Reasons = append(r.Reasons, "new_suspect")
			r.ExpiresAt = time.Now().Add(m.config.PendingTTL)
		}
	}

	// Write to enforcement set if state changed
	if r.State != oldState {
		reason := "threshold"
		if len(r.Reasons) > 0 {
			reason = r.Reasons[len(r.Reasons)-1]
		}
		if err := m.enforcer.Apply(r.IP, oldState, r.State, reason); err != nil {
			log.Printf("[botguard] enforce error for %s: %v", r.IP, err)
		}

		// Update stats
		m.mu.Lock()
		m.stats.Classified++
		switch r.State {
		case StateAllow:
			m.stats.AllowCount++
		case StateGrey:
			m.stats.GreyCount++
		case StateBan:
			m.stats.BanCount++
		case StateEmergency:
			m.stats.EmergencyCount++
		case StatePending:
			m.stats.PendingCount++
		}
		m.mu.Unlock()

		// Publish event
		m.bus.Publish(eventbus.NewEvent(eventbus.EventBan, ModuleName).
			WithIP(r.IP.String()).
			WithMessage(fmt.Sprintf("Bot guard: %s → %s", oldState, r.State)).
			WithData("old_state", oldState.String()).
			WithData("new_state", r.State.String()).
			WithData("hit_count", r.HitCount).
			WithData("reason", reason))
	}
}

// getOrCreate returns or creates an IPRecord for the given address.
func (m *Module) getOrCreate(ip netip.Addr) *IPRecord {
	m.ipsMu.Lock()
	defer m.ipsMu.Unlock()

	if r, ok := m.ips[ip]; ok {
		return r
	}

	r := &IPRecord{
		IP:        ip,
		State:     StateUnknown,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}
	m.ips[ip] = r
	return r
}

// runCleanup periodically removes expired records from the state map.
func (m *Module) runCleanup(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.pruneExpired()
		}
	}
}

// pruneExpired removes records whose TTL has expired.
func (m *Module) pruneExpired() {
	m.ipsMu.Lock()
	defer m.ipsMu.Unlock()

	now := time.Now()
	for ip, r := range m.ips {
		if r.Expired() || now.Sub(r.LastSeen) > 30*time.Minute {
			delete(m.ips, ip)
		}
	}
}

// GetIPRecord returns the current record for an IP (for CLI status queries).
func (m *Module) GetIPRecord(ip netip.Addr) (*IPRecord, bool) {
	m.ipsMu.RLock()
	defer m.ipsMu.RUnlock()

	r, ok := m.ips[ip]
	return r, ok
}

// GetStats returns a copy of the current statistics.
func (m *Module) GetStats() GuardStats {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.stats
}
