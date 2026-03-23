// =============================================================================
// NFTBan v1.0 - Port Scan Detection Module (Go Wrapper)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Go module wrapper for portscan detection with event bus integration"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/portscan/main.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package portscan

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

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

const (
	ModuleName    = "portscan"
	ModuleVersion = "1.0.0"

	// Check interval
	DefaultCheckInterval = constants.PortscanCheckInterval
)

// getPortscanScript returns the portscan script path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getPortscanScript() string {
	cfg := nftbanconf.MustLoad()
	path := filepath.Join(cfg.LibDir, "core", "nftban_portscan.sh")
	// v1.33.0: Validate path exists and is under LibDir (P1-4)
	if !strings.HasPrefix(path, cfg.LibDir) {
		log.Printf("[portscan] suspicious script path: %s", path)
		return ""
	}
	return path
}

// portscanConfig holds module configuration loaded from config files
type portscanConfig struct {
	// From main.conf
	Enabled bool
	Mode    string // auto, classic, suricata, hybrid

	// Ban thresholds (from classic.conf or suricata.conf)
	BanThreshold int           // Number of detections before ban
	BanDuration  time.Duration // Default ban duration
	TrackWindow  time.Duration // Time window to track events
}

// ipTracker tracks portscan events per IP
type ipTracker struct {
	count     int
	firstSeen time.Time
	lastSeen  time.Time
}

// Module implements the portscan detection module
type Module struct {
	bus           *eventbus.Bus
	status        module.Status
	mu            sync.RWMutex
	cancel        context.CancelFunc
	checkInterval time.Duration

	// Configuration from files
	config portscanConfig

	// Runtime state
	mode          string // classic, suricata, hybrid, auto
	enabled       bool
	suricataAvail bool
	scansDetected int64

	// IP tracking for ban decisions
	ipTrackers    map[string]*ipTracker
	bannedIPs     map[string]time.Time // Track recently banned to avoid duplicates
}

// New creates a new portscan detection module
func New() *Module {
	m := &Module{
		status:        module.NewStatus(ModuleName),
		checkInterval: DefaultCheckInterval,
		mode:          "auto",
		enabled:       true,
		config: portscanConfig{
			Enabled:      true,
			Mode:         "auto",
			BanThreshold: 3,                    // Default: 3 detections
			BanDuration:  constants.PortscanBanDuration,  // Default: 30 min ban
			TrackWindow:  constants.PortscanTrackWindow,  // Default: 5 min window
		},
	}
	// Load config from files (will override defaults)
	m.loadConfig()
	return m
}

// loadConfig loads configuration from config files with .local overrides
func (m *Module) loadConfig() {
	cfg := nftbanconf.MustLoad()
	configDir := filepath.Join(cfg.ConfigDir, "conf.d", "portscan")

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
		case "PORTSCAN_ENABLED":
			m.config.Enabled = strings.ToLower(value) == "true"
		case "PORTSCAN_MODE":
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
		case "PORTSCAN_CLASSIC_MIN_PORTS":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanThreshold = v
			}
		case "PORTSCAN_CLASSIC_TIME_WINDOW":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.TrackWindow = time.Duration(v) * time.Second
			}
		case "PORTSCAN_CLASSIC_BAN_DEFAULT":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanDuration = time.Duration(v) * time.Second
			}
		// Suricata mode thresholds
		case "PORTSCAN_SURICATA_BAN_DURATION_SHORT":
			if v, err := strconv.Atoi(value); err == nil {
				m.config.BanDuration = time.Duration(v) * time.Second
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
	// Source the script and get mode (VULN-20: quote path via $1)
	out, err := exec.Command("bash", "-c",
		"source \"$1\" 2>/dev/null && nftban_portscan_load_config && _nftban_portscan_detect_mode", "_", scriptPath).Output()
	if err != nil {
		m.mode = "classic" // Default fallback
		return
	}
	m.mode = strings.TrimSpace(string(out))

	// Check Suricata availability
	out, _ = exec.Command("bash", "-c",
		"source \"$1\" 2>/dev/null && _nftban_portscan_suricata_is_available && echo yes || echo no", "_", scriptPath).Output()
	m.suricataAvail = strings.TrimSpace(string(out)) == "yes"
}

// enable enables portscan detection
func (m *Module) enable() error {
	cmd := exec.Command("bash", "-c", "source \"$1\" && nftban_portscan_enable", "_", getPortscanScript())
	return cmd.Run()
}

// disable disables portscan detection
func (m *Module) disable() error {
	cmd := exec.Command("bash", "-c", "source \"$1\" && nftban_portscan_disable", "_", getPortscanScript())
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
	cmd := exec.Command("bash", "-c", "source \"$1\" && nftban_portscan_run", "_", getPortscanScript())
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
	if e.IP == "" {
		return
	}

	m.mu.Lock()
	m.scansDetected++
	m.status.RecordEvent()

	// Track IP for ban threshold
	if m.ipTrackers == nil {
		m.ipTrackers = make(map[string]*ipTracker)
	}
	if m.bannedIPs == nil {
		m.bannedIPs = make(map[string]time.Time)
	}

	// Skip if recently banned
	if bannedAt, exists := m.bannedIPs[e.IP]; exists {
		if time.Since(bannedAt) < m.config.BanDuration {
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

	shouldBan := tracker.count >= m.config.BanThreshold
	scanCount := tracker.count
	banDuration := m.config.BanDuration
	if shouldBan {
		m.bannedIPs[e.IP] = time.Now()
	}
	m.mu.Unlock()

	// Trigger ban if threshold exceeded
	if shouldBan && m.bus != nil {
		m.bus.Publish(eventbus.NewEvent(eventbus.EventBan, ModuleName).
			WithIP(e.IP).
			WithMessage("Banning " + e.IP + ": portscan threshold exceeded").
			WithSeverity(eventbus.SeverityCritical).
			WithData("duration", banDuration.String()).
			WithData("reason", "portscan_detection").
			WithData("scan_count", scanCount))
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
