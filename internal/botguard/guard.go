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
	"io"
	"log"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
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

	// v1.209 — direct OpQueue handle so the standalone BotScan batch-signal consumer can
	// route BotScan bans to the DURABLE, drop-enforced blacklist_manual_{v4,v6} sets when
	// BotGuard classification is disabled (http_bot_ban is unenforced then). Set in InitEnforcer.
	opQueue *opqueue.OpQueue
	// v1.209 — daemon SourceIndex so consumer-applied BotScan bans record provenance source=botscan
	// (EnqueueBan's Source field does NOT reach source_index; the reconcile path would tag "unknown").
	sourceIndex *opqueue.SourceIndex

	// State map: tracked IPs and their classification
	ips   map[netip.Addr]*IPRecord
	ipsMu sync.RWMutex

	// v1.191 8B inc5A — TEMPORARY decision cache. An OBSERVATION / state-transition layer
	// fed by batch signals; it does NOT enforce, persist, or create durable state in this
	// increment (interim throttling is 5B). Durable allow/deny remain the nft sets' job.
	decisionCache *decisioncache.Cache

	// v1.191 8B inc7 — last restart warm-up replay stats (internal/diagnostic only; NOT wired
	// to schema/metrics in this increment).
	lastWarmup WarmupStats

	// Statistics
	stats GuardStats
}

// New creates a new bot guard module.
func New() *Module {
	cfg := DefaultConfig()
	return &Module{
		status:        module.NewStatus(ModuleName),
		config:        cfg,
		reader:        NewSuspectReader(),
		ips:           make(map[netip.Addr]*IPRecord),
		decisionCache: decisioncache.New(decisionCacheConfigFrom(cfg)),
	}
}

// decisionCacheConfigFrom maps operator config (v1.191 8B config-knobs) to the decision-cache
// limits. Values are already validated/clamped at parse time; decisioncache.New() additionally
// fills any zero with its own safe default (so there is never an unlimited cache).
func decisionCacheConfigFrom(cfg *Config) decisioncache.Config {
	if cfg == nil {
		return decisioncache.DefaultConfig()
	}
	return decisioncache.Config{
		MaxEntries:    cfg.CacheMaxEntries,
		MaxCandidates: cfg.CacheMaxCandidates,
		V6PrefixBits:  cfg.CacheV6PrefixBits,
		PerFamilyCap:  cfg.CacheMaxPerFamily,
		PerHostCap:    cfg.CacheMaxPerHost,
	}
}

// rebuildDecisionCacheFromConfig (re)constructs the decision cache from the current operator
// config. Called from Init() after the config is loaded so operator cache caps take effect.
func (m *Module) rebuildDecisionCacheFromConfig() {
	m.decisionCache = decisioncache.New(decisionCacheConfigFrom(m.config))
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

	// v1.191 8B config-knobs — (re)build the decision cache from the loaded operator config so
	// HTTP_BOT_CACHE_* overrides take effect (New() built it from defaults before config load).
	m.rebuildDecisionCacheFromConfig()

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
	m.opQueue = queue // v1.209: BotScan bans → blacklist_manual via the queue when BotGuard disabled
}

// InitSourceIndex wires the daemon's SourceIndex so consumer-applied BotScan bans record
// provenance source=botscan (v1.209). Called by the daemon after the SourceIndex is created.
func (m *Module) InitSourceIndex(si *opqueue.SourceIndex) {
	m.sourceIndex = si
}

// Start begins the classification loop.
func (m *Module) Start(ctx context.Context) error {
	if !m.config.Enabled {
		log.Printf("[botguard] Module disabled in config")
		// v1.209 — BotScan (Clock-3 shell) writes ban signals to batch_signals.jsonl. Its only
		// consumer used to live in the classifier tick, which never ran when BotGuard was
		// disabled → BotScan bans were inert fleet-wide. Run a STANDALONE, bounded, age-filtered
		// consumer that routes BotScan bans to the durable, drop-enforced blacklist_manual_{v4,v6}
		// sets — WITHOUT enabling BotGuard classification (no suspect-read / FCrDNS / classifier).
		// Requires the OpQueue (set unconditionally in InitEnforcer).
		if m.config.BatchSignalFile != "" && m.opQueue != nil {
			ctx, m.cancel = context.WithCancel(ctx)
			go m.runBatchSignalConsumer(ctx)
			log.Printf("[botguard] BotScan batch-signal consumer started (classification disabled; bans → blacklist_manual)")
		}
		return nil
	}

	if m.enforcer == nil {
		return fmt.Errorf("enforcer not initialized — call InitEnforcer before Start")
	}

	ctx, m.cancel = context.WithCancel(ctx)

	// v1.191 8B inc7 — bounded warm-up: replay the recent tail of batch_signals.jsonl into the
	// decision cache so a restart does not lose in-flight TEMPORARY classification. Bounded
	// (bytes/lines/age/accepted/budget) — safe on 100–300-site hosts; never enforces, never
	// persists, and cannot block startup beyond its budget. Failure degrades to a no-op.
	m.lastWarmup = m.warmupFromBatchSignals(ctx, warmupLimitsFrom(m.config))

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
	// v1.209 — BotScan signal-consumer (un-gate) observability.
	BatchSignalsApplied       int64 `json:"batch_signals_applied"`
	BatchSignalsExpired       int64 `json:"batch_signals_expired"`
	BatchSignalsMalformed     int64 `json:"batch_signals_malformed"`
	BatchConsumerRuns         int64 `json:"batch_consumer_runs"`
	BatchConsumerStaleBacklog bool  `json:"batch_consumer_stale_backlog"`
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
		"batch_signals_processed":      e.BatchSignalsProcessed,
		"batch_signals_applied":        e.BatchSignalsApplied,
		"batch_signals_expired":        e.BatchSignalsExpired,
		"batch_signals_malformed":      e.BatchSignalsMalformed,
		"batch_consumer_runs":          e.BatchConsumerRuns,
		"batch_consumer_stale_backlog": e.BatchConsumerStaleBacklog,
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

		BatchSignalsApplied:       m.stats.BatchSignalsApplied,
		BatchSignalsExpired:       m.stats.BatchSignalsExpired,
		BatchSignalsMalformed:     m.stats.BatchSignalsMalformed,
		BatchConsumerRuns:         m.stats.BatchConsumerRuns,
		BatchConsumerStaleBacklog: m.stats.BatchConsumerStaleBacklog,
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

	// v1.191 8B inc5B2 — cadence-gap gate: constrain the request-blind hit-count escalation so
	// it can only throttle/ban IPs with dynamic-endpoint class evidence. Browser-like / mixed /
	// unknown suspects are NOT rate-banned (no browser-burst false positives); identity/verify
	// decisions pass through unchanged. This is the ONLY change to the classification path.
	result = m.gateInterimRateEscalation(r, result)

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

// v1.209 — BotScan batch-signal consumer constants.
const (
	botscanManualSetV4   = "blacklist_manual_ipv4" // durable, drop-enforced (independent of BotGuard)
	botscanManualSetV6   = "blacklist_manual_ipv6"
	botscanProvenanceSrc = "botscan"
	botscanManualBanTTL  = 24 * time.Hour // BotScan-originated blacklist_manual ban TTL (behavioral; re-confirmable)
	botscanManualGreyTTL = 1 * time.Hour
)

// processBatchSignals reads a BOUNDED TAIL of batch_signals.jsonl (Clock-3 shell botscan), applies
// only FRESH signals (within WarmupMaxAge), and truncates the file. STALE signals (older than the
// cutoff) and any backlog beyond the tail window are QUARANTINED — discarded + counted, NEVER
// applied — so a multi-day unconsumed backlog cannot flood-apply. Bounded by WarmupMaxBytes/Lines/
// Accepted (never slurps the whole file → no OOM on a 24MB queue).
//
// Routing: when BotGuard is ENABLED, applies via the existing BotGuard path (http_bot_ban, which is
// drop-wired then). When BotGuard is DISABLED, routes BotScan bans to the durable, drop-enforced
// blacklist_manual_{v4,v6} sets (http_bot_ban is NOT drop-wired when BotGuard is off). Single
// owner: the BotGuard tick when enabled, the standalone consumer when disabled — never both.
func (m *Module) processBatchSignals() {
	signalFile := m.config.BatchSignalFile
	if signalFile == "" {
		return
	}
	f, err := os.Open(filepath.Clean(signalFile)) // #nosec G304 -- path from nftbanconf (trusted)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("[botguard] batch signal read error: %v", err)
		}
		return // missing → normal
	}
	fi, err := f.Stat()
	if err != nil || fi.Size() == 0 {
		_ = f.Close()
		return
	}
	size := fi.Size()

	// Bounded TAIL: newest signals are appended at the end. Seek to the last maxBytes so we never
	// read a multi-MiB backlog into memory; the un-read head is discarded by the truncate below
	// (it is the stale backlog — intended quarantine).
	maxBytes := m.config.WarmupMaxBytes
	var startOff int64
	staleBeyondWindow := false
	if maxBytes > 0 && size > maxBytes {
		startOff = size - maxBytes
		staleBeyondWindow = true
	}
	if _, err := f.Seek(startOff, io.SeekStart); err != nil {
		_ = f.Close()
		return
	}
	reader := bufio.NewReader(f)
	if startOff > 0 {
		if _, err := reader.ReadString('\n'); err != nil { // drop the partial first line
			_ = f.Close()
			return
		}
	}

	var cutoff int64
	if m.config.WarmupMaxAge > 0 {
		cutoff = time.Now().Add(-m.config.WarmupMaxAge).Unix()
	}
	maxLines := m.config.WarmupMaxLines
	maxAccepted := m.config.WarmupMaxAccepted

	var fresh []BatchSignal
	var scanned, expired, malformed int
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64<<10), 256<<10)
	for scanner.Scan() {
		if maxLines > 0 && scanned >= maxLines {
			break
		}
		line := scanner.Bytes()
		scanned++
		if len(line) == 0 {
			continue
		}
		var sig BatchSignal
		if err := json.Unmarshal(line, &sig); err != nil || sig.IP == "" {
			malformed++
			continue
		}
		if cutoff > 0 && sig.TS != 0 && sig.TS < cutoff {
			expired++ // STALE → quarantine, never apply
			continue
		}
		fresh = append(fresh, sig)
		if maxAccepted > 0 && len(fresh) >= maxAccepted {
			break
		}
	}
	_ = scanner.Err()
	_ = f.Close()

	// Truncate AFTER reading (atomic empty write). Drops the un-read stale head — the quarantine.
	if err := os.WriteFile(signalFile, nil, 0600); err != nil { // #nosec G306 -- truncate to empty
		log.Printf("[botguard] batch signal truncate error: %v", err)
	}

	toManual := !m.config.Enabled
	applied := 0
	for i := range fresh {
		if toManual {
			if m.applyBotscanBanSignal(&fresh[i]) {
				applied++
			}
		} else {
			m.applyBatchSignal(&fresh[i]) // existing BotGuard path (http_bot_ban, drop-wired when enabled)
			applied++
		}
	}

	m.mu.Lock()
	m.stats.BatchSignalsProcessed += int64(scanned)
	m.stats.BatchSignalsApplied += int64(applied)
	m.stats.BatchSignalsExpired += int64(expired)
	m.stats.BatchSignalsMalformed += int64(malformed)
	m.stats.BatchConsumerRuns++
	m.stats.BatchConsumerStaleBacklog = staleBeyondWindow || expired > 0
	m.mu.Unlock()

	if (applied > 0 || expired > 0) && m.logger != nil {
		m.logger.LogEvent("INFO", fmt.Sprintf("batch consumer: applied=%d expired=%d malformed=%d scanned=%d stale_backlog=%v to_manual=%v",
			applied, expired, malformed, scanned, staleBeyondWindow, toManual))
	}
}

// applyBotscanBanSignal enforces a FRESH BotScan batch signal to the DURABLE, drop-enforced
// blacklist_manual_{v4,v6} set (NOT http_bot_ban, which is unenforced when BotGuard is disabled).
// Used by the standalone consumer when BotGuard classification is off. Browser-like/static/admin
// classes are suppressed (never ban from class alone). Whitelist/admin/session safety is preserved
// by firewall RULE ORDER (the whitelist `accept` precedes the blacklist_manual `drop`, exactly as
// for every feed/manual ban). Provenance: source=botscan. Returns true if a ban was enqueued.
func (m *Module) applyBotscanBanSignal(sig *BatchSignal) bool {
	if m.opQueue == nil {
		return false
	}
	ip, err := netip.ParseAddr(sig.IP)
	if err != nil {
		return false
	}
	if sig.Action != "ban" && sig.Action != "grey" {
		return false // only ban/grey actions enforce; allow_demote/extend are no-ops here
	}
	// keep decision-cache observability consistent (harmless; never durable)
	m.recordDecisionTransition(sig, ip)
	// browser-like / static / e-shop / admin fan-out → never ban from class alone (fail-safe)
	if m.suppressBrowserLikeBatchBan(sig) {
		if m.config.LogDecisions {
			log.Printf("[botguard] botscan: suppressed_browser_like %s class=%s action=%s",
				ip, sig.NormalizedRequestClass(), sig.Action)
		}
		return false
	}
	setName := botscanManualSetV4
	if ip.Is6() {
		setName = botscanManualSetV6
	}
	ttl := botscanManualBanTTL
	if sig.Action == "grey" {
		ttl = botscanManualGreyTTL
	}
	reason := botscanProvenanceSrc
	if len(sig.Reasons) > 0 {
		reason = botscanProvenanceSrc + ":" + sig.Reasons[0]
	}
	ttlSec := uint32(ttl / time.Second) // #nosec G115 -- bounded constant (<= 24h), fits uint32
	if err := m.opQueue.EnqueueBan(setName, ip.String(), ttlSec, botscanProvenanceSrc, reason); err != nil {
		log.Printf("[botguard] botscan blacklist_manual enqueue error for %s: %v", ip, err)
		return false
	}
	// v1.209 — record provenance source=botscan (EnqueueBan's Source does NOT reach source_index;
	// without this the reconcile path tags the element "unknown"). blacklist_manual is a persisted set.
	if m.sourceIndex != nil {
		m.sourceIndex.AddWithExpiry(setName, ip.String(), botscanProvenanceSrc, time.Now().Add(ttl).Unix())
	}
	m.mu.Lock()
	m.stats.BanCount++
	m.mu.Unlock()
	if m.logger != nil {
		m.logger.LogEvent("INFO", fmt.Sprintf("botscan ban → %s ip=%s ttl=%ds reason=%s", setName, ip, ttlSec, reason))
	}
	return true
}

// runBatchSignalConsumer drains BotScan batch signals on a ticker, INDEPENDENT of the BotGuard
// classifier loop. Used only when BotGuard classification is disabled but BotScan (Clock-3) is
// producing ban signals — so BotScan bans apply without enabling BotGuard. No suspect-read, no
// FCrDNS, no classifier; only the bounded + age-filtered processBatchSignals drain.
func (m *Module) runBatchSignalConsumer(ctx context.Context) {
	interval := m.config.LoopInterval
	if interval <= 0 {
		interval = 60 * time.Second
	}
	// Brief settle before the FIRST drain: module Start() (and this goroutine) runs in daemon init
	// BEFORE the daemon creates + wires the SourceIndex (InitSourceIndex) and starts the OpQueue.
	// Draining immediately would apply bans with m.sourceIndex==nil → provenance recorded as
	// "unknown". A short wait lets init finish wiring; the ticker cadence is unaffected.
	select {
	case <-ctx.Done():
		return
	case <-time.After(3 * time.Second):
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	m.processBatchSignals() // first drain (SourceIndex + OpQueue wired by now)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.processBatchSignals()
		}
	}
}

// cacheStateFor maps a structured request_class (+ the signal's action) to a TEMPORARY
// decision-cache state and its TTL. It NEVER returns a durable state, and browser-like
// classes are never blocked from class/rate alone. ttl==0 means "use the cache default for
// that state"; blocked_temporarily always carries a positive ban/grey TTL.
//
//	static / static404 / eshop_fanout / admin_ajax → legit_temporarily (browser-like; no ban)
//	dynamic_abuse / login_api / scanner             → blocked_temporarily IFF the existing
//	                                                   action indicates ban/block, else ambiguous
//	mixed / unknown                                 → ambiguous (hold briefly, never block)
func (m *Module) cacheStateFor(class, action string) (decisioncache.State, time.Duration) {
	switch class {
	case "static", "static404", "eshop_fanout", "admin_ajax":
		return decisioncache.StateLegitTemporarily, 0
	case "dynamic_abuse", "login_api", "scanner":
		switch action {
		case "ban":
			return decisioncache.StateBlockedTemporarily, m.config.BanTTL
		case "grey":
			return decisioncache.StateBlockedTemporarily, m.config.GreyTTL
		default:
			// Abuse class without an explicit block action → do not fabricate a block.
			return decisioncache.StateAmbiguous, 0
		}
	default:
		// "mixed" and any unexpected/garbage class string fail safe to ambiguous.
		return decisioncache.StateAmbiguous, 0
	}
}

// recordDecisionTransition observes a batch signal into the temporary decision cache. It
// uses ONLY the structured fields (NormalizedRequestClass / ResolvedFamily) — never a grep
// of the free-text reasons. It is fully fail-safe: any cache error is logged and ignored;
// it never enforces and never escalates a browser-like signal to a block. No durable state
// and no on-disk/shell cache is ever created here.
func (m *Module) recordDecisionTransition(sig *BatchSignal, ip netip.Addr) {
	if m.decisionCache == nil {
		return // fail safe: no cache → no-op (legacy path still runs)
	}
	class := sig.NormalizedRequestClass()
	family := sig.ResolvedFamily()
	state, ttl := m.cacheStateFor(class, sig.Action)

	// v1.191 8B inc5B1 — never let a browser-like (legit) observation override an ACTIVE
	// higher-confidence abuse block. If the IP is currently blocked_temporarily, preserve it
	// (no downgrade to legit). The suppression early-return still prevents a NEW ban, while
	// the existing block stays in force — durable/abuse authority is not weakened by a later
	// browser-like signal.
	if state == decisioncache.StateLegitTemporarily {
		if cur, ok := m.decisionCache.Peek(ip); ok && cur.State == decisioncache.StateBlockedTemporarily {
			return
		}
	}

	rec := decisioncache.Record{
		IP:              ip,
		Family:          family,
		RequestClass:    class,
		State:           state,
		Reason:          "batch_signal:" + sig.Action,
		EvidenceSummary: strings.Join(sig.Reasons, ","),
	}
	if err := m.decisionCache.Put(rec, ttl); err != nil {
		// A cache error must NEVER escalate to a block. Log and move on; the legacy
		// enforce path (preserved below) is the only thing that can ban in inc5A.
		log.Printf("[botguard] decision-cache put ip=%s class=%s state=%s failed (ignored): %v",
			ip, class, state, err)
	}
}

// isBrowserLike reports whether a structured request_class is a browser/static/admin
// fan-out class that must never be banned from class/rate alone.
func isBrowserLike(class string) bool {
	switch class {
	case "static", "static404", "eshop_fanout", "admin_ajax":
		return true
	}
	return false
}

// suppressBrowserLikeBatchBan decides whether a batch signal's ban/grey enforcement should be
// SUPPRESSED because its STRUCTURED class proves browser/static/admin fan-out. The decision
// uses only the structured class (never the free-text reasons) and is independent of cache
// success — so a cache error still suppresses a browser-like ban (never ban browser-like by
// class/rate). Abuse classes (dynamic_abuse/login_api/scanner) and mixed/unknown are never
// suppressed here. This affects ONLY the BotScan→BotGuard batch path; durable blacklist/feed/
// manual/whitelist and the DDoS/portscan/Suricata/LoginMon paths are untouched.
func (m *Module) suppressBrowserLikeBatchBan(sig *BatchSignal) bool {
	if sig.Action != "ban" && sig.Action != "grey" {
		return false
	}
	return isBrowserLike(sig.NormalizedRequestClass())
}

// isDynamicAbuseClass reports whether a structured request_class is a clearly dynamic
// endpoint class that may receive the conservative interim cadence-gap posture.
func isDynamicAbuseClass(class string) bool {
	switch class {
	case "dynamic_abuse", "login_api", "scanner":
		return true
	}
	return false
}

// interimPosture is the v1.191 8B inc5B2 cadence-gap decision for an IP.
type interimPosture int

const (
	interimNone           interimPosture = iota // no interim action (browser-like/mixed/unknown/legit/ambiguous)
	interimProtectDynamic                       // dynamic class evidence → interim protection allowed
	interimHoldBlocked                          // already a temporary block → hold, avoid reclassification
)

// interimDynamicPosture maps a cached decision record to the cadence-gap posture. It is the
// G1 policy: only clearly dynamic endpoint classes (dynamic_abuse/login_api/scanner) in a
// candidate/checking/blocked state earn interim protection; browser-like, mixed, unknown,
// legit_temporarily and ambiguous never do (no browser-burst punishment).
func (m *Module) interimDynamicPosture(rec decisioncache.Record) interimPosture {
	switch rec.State {
	case decisioncache.StateBlockedTemporarily:
		// Already a temporary block. If it was a dynamic decision, protection is in force;
		// either way, hold without re-running expensive classification while active.
		if isDynamicAbuseClass(rec.RequestClass) {
			return interimProtectDynamic
		}
		return interimHoldBlocked
	case decisioncache.StateCandidate, decisioncache.StateChecking:
		if isDynamicAbuseClass(rec.RequestClass) {
			return interimProtectDynamic
		}
		return interimNone // browser-like / mixed / unknown candidate → no rate punishment
	default: // legit_temporarily, ambiguous, anything else
		return interimNone
	}
}

// interimPostureForIP looks up the cadence-gap posture for an IP from the decision cache.
// Fail-safe: a nil cache or a miss/expired entry yields interimNone — which, for a rate
// escalation, means "do not rate-ban" (never bans browser-like by class/rate on cache error).
func (m *Module) interimPostureForIP(ip netip.Addr) interimPosture {
	if m.decisionCache == nil {
		return interimNone
	}
	rec, ok := m.decisionCache.Peek(ip)
	if !ok {
		return interimNone
	}
	return m.interimDynamicPosture(rec)
}

// isRateEscalationReason reports whether a classifier decision came purely from the
// request-blind L4 meter hit-count ladder (the original browser-burst false-positive path).
func isRateEscalationReason(reason string) bool {
	return reason == "repeated_suspect" || reason == "persistent_suspect"
}

// gateInterimRateEscalation is the v1.191 8B inc5B2 cadence-gap gate. It constrains the
// request-blind hit-count escalation so it can ONLY ban/throttle IPs with dynamic-endpoint
// class evidence in the decision cache. Identity/verification decisions (fcrdns_*, denied_bot,
// allow, pending, enqueue) are NOT rate escalations and pass through unchanged — only the
// "repeated_suspect"/"persistent_suspect" rate ladder is gated. With dynamic evidence the
// escalation proceeds (interim protection during BotScan's slow cadence); without it (browser-
// like / mixed / unknown / cache error) the escalation is HELD at the current state with no new
// enforcement. Gross/bodyless floods remain covered by the raised L4 meter + the DDoS layer.
func (m *Module) gateInterimRateEscalation(r *IPRecord, result ClassifyResult) ClassifyResult {
	if !isRateEscalationReason(result.Reason) {
		return result
	}
	if m.interimPostureForIP(r.IP) == interimProtectDynamic {
		return result // dynamic-class evidence → allow the interim escalation
	}
	if m.config.LogDecisions {
		log.Printf("[botguard] %s: interim_rate_escalation_held (no dynamic evidence; classifier wanted %s/%s) — not throttled/banned by rate alone",
			r.IP, result.State, result.Reason)
	}
	return ClassifyResult{State: r.State, Reason: "interim_rate_escalation_held_no_dynamic_evidence"}
}

// applyBatchSignal applies a single batch signal from the shell botscan.
func (m *Module) applyBatchSignal(sig *BatchSignal) {
	ip, err := netip.ParseAddr(sig.IP)
	if err != nil {
		log.Printf("[botguard] batch signal invalid IP %q: %v", sig.IP, err)
		return
	}

	// v1.191 8B inc5A — record a TEMPORARY decision-cache transition from the STRUCTURED
	// signal (request_class/family). Never grep free-text reasons; never create durable state.
	m.recordDecisionTransition(sig, ip)

	// v1.191 8B inc5B1 — cache-aware suppression of browser-like FALSE-POSITIVE batch bans.
	// If the STRUCTURED class is browser/static/admin fan-out and the action is ban/grey, do
	// NOT add the IP to http_bot_ban from class alone: keep the cache as legit_temporarily
	// (recorded above) and skip the legacy enforce for THIS signal. This does NOT unban an
	// already-enforced IP and never touches durable blacklist/feed/manual/whitelist or the
	// DDoS/portscan/Suricata/LoginMon paths. The decision is independent of cache success, so
	// a cache error still suppresses (fail-safe: never ban browser-like by class/rate). Abuse
	// classes and mixed/unknown are NOT suppressed (handled by the legacy path below).
	if m.suppressBrowserLikeBatchBan(sig) {
		if m.config.LogDecisions {
			log.Printf("[botguard] %s: suppressed_browser_like_signal (class=%s action=%s) — not added to http_bot_ban",
				ip, sig.NormalizedRequestClass(), sig.Action)
		}
		if m.logger != nil {
			m.logger.LogEvent("INFO", fmt.Sprintf("suppressed_browser_like_signal ip=%s class=%s action=%s",
				ip, sig.NormalizedRequestClass(), sig.Action))
		}
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
