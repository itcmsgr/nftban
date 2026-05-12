// =============================================================================
// NFTBan v1.21.0 - HTTP Bot Guard: Main Controller
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
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/opqueue"
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
	reader     *SuspectReader
	enforcer   *Enforcer
	verifier   *FCrDNSVerifier
	classifier *Classifier
	logger     *Logger

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
		Description: "HTTP Bot Guard: Automated Crawler Detection & Protection",
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

	// Load allowed crawlers for verifier initialization
	allowedBots, err := loadAllowedCrawlers(cfg.AllowedCrawlersFile)
	if err != nil {
		log.Printf("[botguard] warning: could not load allowed crawlers: %v", err)
	}

	// Create FCrDNS verifier
	m.verifier = NewFCrDNSVerifier(cfg, allowedBots)

	// Create classifier (loads allowed + denied configs)
	classifier, err := NewClassifier(cfg, m.verifier)
	if err != nil {
		return fmt.Errorf("init classifier: %w", err)
	}
	m.classifier = classifier

	// Create file logger
	_, _, logFile := getBotguardPaths()
	logDir := filepath.Dir(logFile)
	logger, err := NewLogger(logDir)
	if err != nil {
		log.Printf("[botguard] warning: could not init file logger: %v (continuing with stdout only)", err)
	} else {
		m.logger = logger
	}

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

	if m.logger != nil {
		m.logger.LogEvent("INFO", fmt.Sprintf("HTTP Bot Guard started — loop=%s pressure=%s",
			m.config.LoopInterval, m.config.LoopPressureInterval))
	}

	// Start the FCrDNS verifier worker pool
	go m.verifier.Start(ctx)

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

	// Close file logger
	if m.logger != nil {
		m.logger.LogEvent("INFO", "HTTP Bot Guard stopping")
		if err := m.logger.Close(); err != nil {
			log.Printf("[botguard] logger close error: %v", err)
		}
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

// BotGuardStatusExtra is the typed status payload for the BotGuard
// module's Status().Extra field. Field names map to legacy
// map[string]any keys via JSON tags byte-for-byte; R-12 introduces
// type-safety without an API change.
type BotGuardStatusExtra struct {
	LoopInterval          string `json:"loop_interval"`
	PressureMode          bool   `json:"pressure_mode"`
	TrackedIPs            int64  `json:"tracked_ips"`
	TotalTicks            int64  `json:"total_ticks"`
	SuspectsFound         int64  `json:"suspects_found"`
	Classified            int64  `json:"classified"`
	AllowCount            int64  `json:"allow_count"`
	GreyCount             int64  `json:"grey_count"`
	BanCount              int64  `json:"ban_count"`
	EmergencyCount        int64  `json:"emergency_count"`
	LastTickDuration      string `json:"last_tick_duration"`
	VerifyEnqueued        int64  `json:"verify_enqueued"`
	VerifyCompleted       int64  `json:"verify_completed"`
	VerifyVerified        int64  `json:"verify_verified"`
	VerifyFailed          int64  `json:"verify_failed"`
	BatchSignalsProcessed int64  `json:"batch_signals_processed"`
}

// ToExtraInfo serializes the typed struct into the module.ExtraInfo
// map[string]any contract expected by module.Status.Extra.
func (e BotGuardStatusExtra) ToExtraInfo() module.ExtraInfo {
	return module.ExtraInfo{
		"loop_interval":           e.LoopInterval,
		"pressure_mode":           e.PressureMode,
		"tracked_ips":             e.TrackedIPs,
		"total_ticks":             e.TotalTicks,
		"suspects_found":          e.SuspectsFound,
		"classified":              e.Classified,
		"allow_count":             e.AllowCount,
		"grey_count":              e.GreyCount,
		"ban_count":               e.BanCount,
		"emergency_count":         e.EmergencyCount,
		"last_tick_duration":      e.LastTickDuration,
		"verify_enqueued":         e.VerifyEnqueued,
		"verify_completed":        e.VerifyCompleted,
		"verify_verified":         e.VerifyVerified,
		"verify_failed":           e.VerifyFailed,
		"batch_signals_processed": e.BatchSignalsProcessed,
	}
}

// Status returns the current module status.
func (m *Module) Status() module.Status {
	m.mu.RLock()
	defer m.mu.RUnlock()

	m.status.UpdateUptime()
	extra := BotGuardStatusExtra{
		LoopInterval:          m.config.LoopInterval.String(),
		PressureMode:          m.stats.PressureMode,
		TrackedIPs:            m.stats.TrackedIPs,
		TotalTicks:            m.stats.TickCount,
		SuspectsFound:         m.stats.SuspectsFound,
		Classified:            m.stats.Classified,
		AllowCount:            m.stats.AllowCount,
		GreyCount:             m.stats.GreyCount,
		BanCount:              m.stats.BanCount,
		EmergencyCount:        m.stats.EmergencyCount,
		LastTickDuration:      m.stats.LastTickDuration.String(),
		VerifyEnqueued:        m.stats.VerifyEnqueued,
		VerifyCompleted:       m.stats.VerifyCompleted,
		VerifyVerified:        m.stats.VerifyVerified,
		VerifyFailed:          m.stats.VerifyFailed,
		BatchSignalsProcessed: m.stats.BatchSignalsProcessed,
	}
	m.status.Extra = extra.ToExtraInfo()

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
// 1. Drain FCrDNS verification results
// 2. Read kernel suspect set (20-100 IPs, microseconds)
// 3. For each new suspect, create pending record
// 4. Classify pending/unknown IPs via classifier (FCrDNS + config)
// 5. Write decisions to enforcement sets via OpQueue
func (m *Module) tick(ctx context.Context) {
	// Step 1: Drain FCrDNS verification results
	m.drainVerifications()

	// Step 1b: Process batch signals from Clock 3 (shell botscan)
	m.processBatchSignals()

	// Step 2: Read kernel suspect set
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

	// Step 3: Process each suspect
	for _, ip := range suspects {
		record := m.getOrCreate(ip)

		// Update last seen
		record.LastSeen = time.Now()
		record.HitCount++

		// Step 4: Classify if not already in a terminal state
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

// classify determines the classification for an IP using the classifier.
// Delegates to Classifier.Classify() which uses FCrDNS verification and
// crawler config lookup instead of simple threshold logic.
func (m *Module) classify(r *IPRecord) {
	oldState := r.State

	// Delegate to classifier
	result := m.classifier.Classify(r, m.config)

	// Apply result to record
	r.State = result.State
	if result.BotName != "" {
		r.BotName = result.BotName
	}
	r.Reasons = append(r.Reasons, result.Reason)

	// Set expiry based on new state
	switch r.State {
	case StatePending:
		r.ExpiresAt = time.Now().Add(m.config.PendingTTL)
	case StateAllow:
		r.ExpiresAt = time.Now().Add(m.config.AllowTTL)
	case StateGrey:
		r.ExpiresAt = time.Now().Add(m.config.GreyTTL)
	case StateBan:
		r.ExpiresAt = time.Now().Add(m.config.BanTTL)
	case StateEmergency:
		r.ExpiresAt = time.Now().Add(m.config.EmergencyTTL)
	}

	// Track enqueue stats
	if result.Reason == "new_suspect_verify_enqueued" {
		m.mu.Lock()
		m.stats.VerifyEnqueued++
		m.mu.Unlock()
	}

	// Write to enforcement set if state changed
	if r.State != oldState {
		reason := result.Reason
		if err := m.enforcer.Apply(r.IP, oldState, r.State, reason); err != nil {
			log.Printf("[botguard] enforce error for %s: %v", r.IP, err)
			if m.logger != nil {
				m.logger.LogError("enforce", err)
			}
		}

		// Log classification to file
		if m.logger != nil {
			m.logger.LogClassification(r.IP.String(), oldState, r.State, reason, result.BotName, r.HitCount)
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
			WithData("reason", reason).
			WithData("bot_name", result.BotName))
	}
}

// drainVerifications processes all pending FCrDNS verification results.
// Called at the start of each tick to apply verification decisions.
func (m *Module) drainVerifications() {
	for {
		select {
		case result := <-m.verifier.Results():
			m.applyVerification(result)
		default:
			return
		}
	}
}

// applyVerification applies a single FCrDNS result to the IP record.
func (m *Module) applyVerification(vr VerifyResult) {
	record := m.getOrCreate(vr.IP)
	oldState := record.State

	// Update verification fields on the record
	record.VerifyStatus = vr.Status
	record.VerifiedAt = time.Now()
	if vr.BotName != "" {
		record.BotName = vr.BotName
	}

	// Get classification decision from the classifier
	result := m.classifier.ProcessVerification(vr)

	// Update stats
	m.mu.Lock()
	m.stats.VerifyCompleted++
	if vr.Status == VerifyVerified {
		m.stats.VerifyVerified++
	} else {
		m.stats.VerifyFailed++
	}
	m.mu.Unlock()

	// Apply new state
	record.State = result.State
	record.Reasons = append(record.Reasons, result.Reason)

	switch record.State {
	case StateAllow:
		record.ExpiresAt = time.Now().Add(m.config.AllowTTL)
	case StateGrey:
		record.ExpiresAt = time.Now().Add(m.config.GreyTTL)
	case StateBan:
		record.ExpiresAt = time.Now().Add(m.config.BanTTL)
	case StatePending:
		record.ExpiresAt = time.Now().Add(m.config.PendingTTL)
	}

	// Enforce state change
	if record.State != oldState {
		if err := m.enforcer.Apply(record.IP, oldState, record.State, result.Reason); err != nil {
			log.Printf("[botguard] enforce error for %s: %v", record.IP, err)
		}

		// Log verification decision to file
		if m.logger != nil {
			m.logger.LogDecision(record.IP.String(), record.State, result.Reason, result.BotName, vr.Status, vr.Hostname)
		}

		m.mu.Lock()
		m.stats.Classified++
		switch record.State {
		case StateAllow:
			m.stats.AllowCount++
		case StateGrey:
			m.stats.GreyCount++
		case StateBan:
			m.stats.BanCount++
		}
		m.mu.Unlock()

		m.bus.Publish(eventbus.NewEvent(eventbus.EventBan, ModuleName).
			WithIP(record.IP.String()).
			WithMessage(fmt.Sprintf("Bot guard verify: %s → %s", oldState, record.State)).
			WithData("old_state", oldState.String()).
			WithData("new_state", record.State.String()).
			WithData("verify_status", vr.Status.String()).
			WithData("bot_name", result.BotName).
			WithData("hostname", vr.Hostname).
			WithData("reason", result.Reason))
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

// processBatchSignals reads and processes batch_signals.jsonl from Clock 3 (shell botscan).
// Reads all lines, applies each signal as a classification input, then truncates the file.
// Thread-safe: only called from the classification loop goroutine.
func (m *Module) processBatchSignals() {
	signalFile := m.config.BatchSignalFile
	if signalFile == "" {
		return
	}

	// Open the file for reading
	f, err := os.Open(filepath.Clean(signalFile)) // #nosec G304 -- path from nftbanconf (trusted)
	if err != nil {
		if os.IsNotExist(err) {
			return // No signals yet — normal
		}
		log.Printf("[botguard] batch signal read error: %v", err)
		return
	}

	var signals []BatchSignal
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var sig BatchSignal
		if err := json.Unmarshal(line, &sig); err != nil {
			log.Printf("[botguard] batch signal parse error: %v", err)
			continue
		}
		signals = append(signals, sig)
	}
	if err := scanner.Err(); err != nil {
		log.Printf("[botguard] batch signal scanner error: %v", err)
	}
	if err := f.Close(); err != nil {
		log.Printf("[botguard] batch signal file close error: %v", err)
	}

	if len(signals) == 0 {
		return
	}

	// Truncate the file after reading (atomic: write empty file)
	if err := os.WriteFile(signalFile, nil, 0600); err != nil { // #nosec G306 -- truncate to empty
		log.Printf("[botguard] batch signal truncate error: %v", err)
	}

	// Process each signal
	for i := range signals {
		m.applyBatchSignal(&signals[i])
	}

	m.mu.Lock()
	m.stats.BatchSignalsProcessed += int64(len(signals))
	m.mu.Unlock()

	if m.logger != nil {
		m.logger.LogEvent("INFO", fmt.Sprintf("Processed %d batch signals from Clock 3", len(signals)))
	}
}

// applyBatchSignal applies a single batch signal from the shell botscan.
func (m *Module) applyBatchSignal(sig *BatchSignal) {
	ip, err := netip.ParseAddr(sig.IP)
	if err != nil {
		log.Printf("[botguard] batch signal invalid IP %q: %v", sig.IP, err)
		return
	}

	record := m.getOrCreate(ip)
	oldState := record.State

	// Map action to state
	var newState IPState
	switch sig.Action {
	case "ban":
		newState = StateBan
	case "grey":
		newState = StateGrey
	case "allow_demote":
		// Demote from allow to grey (suspicious behavior from previously allowed IP)
		if record.State == StateAllow {
			newState = StateGrey
		} else {
			return // No-op if not currently allowed
		}
	case "allow_extend":
		// Extend allow TTL (confirmed good behavior)
		if record.State == StateAllow {
			record.ExpiresAt = time.Now().Add(m.config.AllowTTL)
			return
		}
		return
	default:
		log.Printf("[botguard] batch signal unknown action %q for %s", sig.Action, sig.IP)
		return
	}

	// Don't downgrade: if already banned, don't move to grey
	if record.State == StateBan && newState == StateGrey {
		return
	}
	// Don't override emergency
	if record.State == StateEmergency {
		return
	}

	// Apply new state
	record.State = newState
	score := sig.Score
	if score > 100 {
		score = 100
	}
	record.Score = int32(score) // #nosec G115 -- clamped to [0,100]
	record.LastSeen = time.Now()
	for _, reason := range sig.Reasons {
		record.Reasons = append(record.Reasons, "batch:"+reason)
	}

	// Set expiry
	switch newState {
	case StateBan:
		record.ExpiresAt = time.Now().Add(m.config.BanTTL)
	case StateGrey:
		record.ExpiresAt = time.Now().Add(m.config.GreyTTL)
	}

	// Enforce state change
	if newState != oldState {
		reason := fmt.Sprintf("batch_signal:%s", sig.Action)
		if err := m.enforcer.Apply(record.IP, oldState, newState, reason); err != nil {
			log.Printf("[botguard] enforce error for batch %s: %v", record.IP, err)
			if m.logger != nil {
				m.logger.LogError("batch_enforce", err)
			}
		}

		// Log classification
		if m.logger != nil {
			m.logger.LogClassification(record.IP.String(), oldState, newState, reason, record.BotName, record.HitCount)
		}

		// Update stats
		m.mu.Lock()
		m.stats.Classified++
		switch newState {
		case StateBan:
			m.stats.BanCount++
		case StateGrey:
			m.stats.GreyCount++
		}
		m.mu.Unlock()

		// Publish event
		m.bus.Publish(eventbus.NewEvent(eventbus.EventBan, ModuleName).
			WithIP(record.IP.String()).
			WithMessage(fmt.Sprintf("Bot guard batch: %s → %s", oldState, newState)).
			WithData("old_state", oldState.String()).
			WithData("new_state", newState.String()).
			WithData("score", sig.Score).
			WithData("reason", reason).
			WithData("source", "clock3_batch"))
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
