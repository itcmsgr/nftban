// =============================================================================
// NFTBan v1.0 - DDoS Protection Module (Go Wrapper)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Go module wrapper for DDoS protection with event bus integration"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/ddos/main.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ddos

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
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
	path := filepath.Join(cfg.LibDir, "core", "nftban_ddos.sh")
	// v1.33.0: Validate path is under LibDir (P1-4)
	if !strings.HasPrefix(path, cfg.LibDir) {
		log.Printf("[ddos] suspicious script path: %s", path)
		return ""
	}
	return path
}

// ddosConfig holds module configuration loaded from config files
type ddosConfig struct {
	// From main.conf
	Enabled bool
	Mode    string // auto, classic, suricata, hybrid

	// Ban thresholds (from classic.conf or suricata.conf)
	EscalateThreshold int           // DDOS_CLASSIC_ESCALATE_THRESHOLD
	BanDurationShort  time.Duration // DDOS_CLASSIC_BAN_DURATION_SHORT
	BanDurationMedium time.Duration // DDOS_CLASSIC_BAN_DURATION_MEDIUM
	BanDurationLong   time.Duration // DDOS_CLASSIC_BAN_DURATION_LONG
	TrackWindow       time.Duration // Time window to track events
}

// ipTracker tracks DDoS events per IP
type ipTracker struct {
	count     int
	firstSeen time.Time
	lastSeen  time.Time
}

// Module implements the DDoS protection module
type Module struct {
	bus           *eventbus.Bus
	status        module.Status
	mu            sync.RWMutex
	cancel        context.CancelFunc
	checkInterval time.Duration

	// Configuration from files
	config ddosConfig

	// Runtime state
	mode          string // classic, suricata, hybrid, auto
	enabled       bool
	suricataAvail bool

	// IP tracking for ban decisions
	ipTrackers    map[string]*ipTracker
	bannedIPs     map[string]time.Time
}

// New creates a new DDoS protection module
func New() *Module {
	m := &Module{
		status:        module.NewStatus(ModuleName),
		checkInterval: DefaultCheckInterval,
		mode:          "auto",
		enabled:       true,
		config: ddosConfig{
			Enabled:           true,
			Mode:              "auto",
			EscalateThreshold: 3,                    // Default: 3 detections
			BanDurationShort:  5 * time.Minute,     // Default: 5 min ban (first)
			BanDurationMedium: 30 * time.Minute,    // Default: 30 min ban (repeat)
			BanDurationLong:   1 * time.Hour,       // Default: 1 hour (persistent)
			TrackWindow:       1 * time.Minute,     // Default: 1 min window
		},
	}
	// Load config from files (will override defaults)
	m.loadConfig()
	return m
}

// loadConfig loads configuration from config files with .local overrides
func (m *Module) loadConfig() {
	cfg := nftbanconf.MustLoad()
	configDir := filepath.Join(cfg.ConfigDir, "conf.d", "ddos")

	// 1. Load main.conf
	mainPath := filepath.Join(configDir, "main.conf")
	if data, err := os.ReadFile(mainPath); err == nil {
		m.parseMainConfig(string(data))
	}

	// 2. Load main.conf.local overrides
	localMainPath := filepath.Join(configDir, "main.conf.local")
	if data, err := os.ReadFile(localMainPath); err == nil {
		m.parseMainConfig(string(data))
	}

	// 2b. Load central override (nftban.conf.local — highest priority)
	centralLocal := filepath.Join(cfg.ConfigDir, "nftban.conf.local")
	if data, err := os.ReadFile(centralLocal); err == nil {
		m.parseMainConfig(string(data))
	}

	// 3. Determine which mode-specific config to load based on mode
	modeConfigFile := "classic.conf"
	if m.config.Mode == "suricata" || (m.config.Mode == "auto" && m.suricataAvail) {
		modeConfigFile = "suricata.conf"
	}

	// 4. Load mode-specific config (classic.conf or suricata.conf)
	modePath := filepath.Join(configDir, modeConfigFile)
	if data, err := os.ReadFile(modePath); err == nil {
		m.parseModeConfig(string(data))
	}

	// 5. Load mode-specific .local override
	localModePath := filepath.Join(configDir, modeConfigFile+".local")
	if data, err := os.ReadFile(localModePath); err == nil {
		m.parseModeConfig(string(data))
	}

	m.enabled = m.config.Enabled
	m.mode = m.config.Mode
}

// parseMainConfig parses main.conf settings
func (m *Module) parseMainConfig(content string) {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		value := strings.Trim(strings.TrimSpace(parts[1]), `"'`)

		switch key {
		case "DDOS_ENABLED":
			m.config.Enabled = strings.ToLower(value) == "true"
		case "DDOS_MODE":
			m.config.Mode = value
		}
	}
}

// parseModeConfig parses classic.conf or suricata.conf settings
func (m *Module) parseModeConfig(content string) {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		value := strings.Trim(strings.TrimSpace(parts[1]), `"'`)

		switch key {
		// Classic mode thresholds
		case "DDOS_CLASSIC_ESCALATE_THRESHOLD":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.EscalateThreshold = v
			}
		case "DDOS_CLASSIC_BAN_DURATION_SHORT":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanDurationShort = time.Duration(v) * time.Second
			}
		case "DDOS_CLASSIC_BAN_DURATION_MEDIUM":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanDurationMedium = time.Duration(v) * time.Second
			}
		case "DDOS_CLASSIC_BAN_DURATION_LONG":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanDurationLong = time.Duration(v) * time.Second
			}
		// Suricata mode thresholds
		case "DDOS_SURICATA_BAN_DURATION_SHORT":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanDurationShort = time.Duration(v) * time.Second
			}
		case "DDOS_SURICATA_BAN_DURATION_LONG":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanDurationLong = time.Duration(v) * time.Second
			}
		}
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
	// VULN-20: quote path via $1
	out, err := exec.Command("bash", "-c", "source \"$1\" && nftban_ddos_get_mode", "_", scriptPath).Output()
	if err != nil {
		m.mode = "classic" // Default fallback
		return
	}
	m.mode = strings.TrimSpace(string(out))

	// Check Suricata availability
	out, _ = exec.Command("bash", "-c", "source \"$1\" && nftban_ddos_suricata_available && echo yes || echo no", "_", scriptPath).Output()
	m.suricataAvail = strings.TrimSpace(string(out)) == "yes"
}

// enable enables DDoS protection
func (m *Module) enable() error {
	cmd := exec.Command("bash", "-c", "source \"$1\" && nftban_ddos_enable", "_", getDDOSScript())
	return cmd.Run()
}

// disable disables DDoS protection
func (m *Module) disable() error {
	cmd := exec.Command("bash", "-c", "source \"$1\" && nftban_ddos_disable", "_", getDDOSScript())
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
	if e.IP == "" {
		return
	}

	m.mu.Lock()
	m.status.RecordEvent()

	// Track IP for ban threshold
	if m.ipTrackers == nil {
		m.ipTrackers = make(map[string]*ipTracker)
	}
	if m.bannedIPs == nil {
		m.bannedIPs = make(map[string]time.Time)
	}

	// Skip if recently banned (use longest duration)
	if bannedAt, exists := m.bannedIPs[e.IP]; exists {
		if time.Since(bannedAt) < m.config.BanDurationLong {
			m.mu.Unlock()
			return
		}
		delete(m.bannedIPs, e.IP)
	}

	// Track this IP
	tracker, exists := m.ipTrackers[e.IP]
	if !exists || time.Since(tracker.firstSeen) > m.config.TrackWindow {
		tracker = &ipTracker{
			count:     0,
			firstSeen: time.Now(),
		}
		m.ipTrackers[e.IP] = tracker
	}
	tracker.count++
	tracker.lastSeen = time.Now()

	shouldBan := tracker.count >= m.config.EscalateThreshold
	eventCount := tracker.count
	// Escalate ban duration based on repeat offenses
	banDuration := m.config.BanDurationShort
	if eventCount >= m.config.EscalateThreshold*3 {
		banDuration = m.config.BanDurationLong
	} else if eventCount >= m.config.EscalateThreshold*2 {
		banDuration = m.config.BanDurationMedium
	}
	if shouldBan {
		m.bannedIPs[e.IP] = time.Now()
	}
	m.mu.Unlock()

	// Trigger ban if threshold exceeded - escalating duration
	if shouldBan && m.bus != nil {
		m.bus.Publish(eventbus.NewEvent(eventbus.EventBan, ModuleName).
			WithIP(e.IP).
			WithMessage("Banning " + e.IP + ": DDoS threshold exceeded").
			WithSeverity(eventbus.SeverityCritical).
			WithData("duration", banDuration.String()).
			WithData("reason", "ddos_protection").
			WithData("event_count", eventCount))
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
