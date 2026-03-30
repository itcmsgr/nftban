// =============================================================================
// NFTBan v1.0.30 - Login Monitor Module (High-Performance Go Implementation)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: loginmon
// Purpose: Go module for login monitoring with signal-based detection
//
// meta:name="loginmon_module"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="loginmon"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="High-performance login monitor using signal-based detection"
//
// Architecture:
// - Implements the module.Module interface for daemon integration
// - Uses internal/loginmon/detector for high-performance signal-based detection
// - Uses internal/loginmon/detector.Scorer for threshold-based ban decisions
// - Dual-mode: Classic (journalctl) or Suricata (EVE JSON)
// - Publishes events to the central event bus
// - Runs log watchers as goroutines
//
// Performance:
// - 20M+ lines/sec on non-match (0 allocations)
// - 3M+ lines/sec on match (2 allocations)
// - 100x improvement over legacy regex-based detection
//
// This module provides automated, risk-based ban decisions
//
// meta:inventory.files="module.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/login/main.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/loginmon/detector"
	"github.com/itcmsgr/nftban/internal/metrics"
	"github.com/itcmsgr/nftban/internal/module"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/safeconv"
)

const (
	ModuleName    = "loginmon"
	ModuleVersion = "1.0.30"

	// Suricata paths (NFTBan alert-only output)
	DefaultEVEPath        = "/var/log/nftban/suricata/eve-alerts.json"
	DefaultSuricataBin    = "/usr/bin/suricata"
	EVEFreshnessThreshold = 60 // seconds

	// Detection intervals
	DefaultCheckInterval = constants.LoginmonCheckInterval
)

// getLoginmonPaths returns paths from central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getLoginmonPaths() (configDir, dataDir, cacheDir, logFile string) {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir + "/conf.d/login",
		cfg.DataDir + "/login",
		cfg.CacheDir + "/login",
		cfg.LogDir + "/login-monitor.log"
}

// Mode represents the operating mode
type Mode string

const (
	ModeAuto     Mode = "auto"
	ModeClassic  Mode = "classic"
	ModeSuricata Mode = "suricata"
	ModeHybrid   Mode = "hybrid"
)

// Module implements the login monitor module
type Module struct {
	bus    *eventbus.Bus
	status module.Status
	mu     sync.RWMutex
	cancel context.CancelFunc

	// High-performance detector (replaces legacy regex)
	registry *detector.Registry
	scorer   *detector.Scorer

	// Configuration
	config *Config
	mode   Mode

	// Runtime state
	suricataAvail    bool
	detectedServices map[string]bool

	// Log watchers
	journalCmd *exec.Cmd
	eveFile    *os.File
	eveReader  *bufio.Reader

	// v1.48.0: File watchers for services that don't log to journalctl
	// (DirectAdmin, cPanel, Plesk use their own log files)
	fileWatcherCmds []*exec.Cmd
}

// New creates a new login monitor module
func New() *Module {
	return &Module{
		status:           module.NewStatus(ModuleName),
		registry:         detector.NewRegistry(),
		scorer:           detector.NewScorerDefault(),
		config:           DefaultConfig(),
		mode:             ModeAuto,
		detectedServices: make(map[string]bool),
	}
}

// Name returns the module identifier
func (m *Module) Name() string {
	return ModuleName
}

// Init initializes the module with the event bus
func (m *Module) Init(bus *eventbus.Bus) error {
	m.bus = bus

	// Subscribe to login events from other sources (e.g., Suricata processor)
	bus.Subscribe(eventbus.EventLoginFailed, m.handleExternalLoginEvent)

	// Load configuration
	if err := m.loadConfig(); err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Detect available services
	m.detectServices()

	// Detect Suricata availability
	m.suricataAvail = m.checkSuricataAvailable()

	// Determine operating mode
	m.mode = m.detectMode()

	m.status.Enabled = m.config.Enabled
	return nil
}

// Start begins the module's background work
func (m *Module) Start(ctx context.Context) error {
	ctx, m.cancel = context.WithCancel(ctx)

	m.mu.Lock()
	m.status.MarkRunning()
	m.mu.Unlock()

	// Publish module start event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStart, ModuleName).
		WithMessage("Login monitor started (high-performance detector)").
		WithData("mode", string(m.mode)).
		WithData("services", m.getServiceList()).
		WithData("detectors", strings.Join(m.registry.Detectors(), ",")))

	// Start appropriate watchers based on mode
	switch m.mode {
	case ModeClassic:
		go m.runJournalWatcher(ctx)
	case ModeSuricata:
		go m.runEVEWatcher(ctx)
	case ModeHybrid:
		go m.runJournalWatcher(ctx)
		go m.runEVEWatcher(ctx)
	}

	// v1.48.0: Start file watchers for panel services that don't log to journalctl
	m.startFileWatchers(ctx)

	// Start score decay goroutine
	go m.runScoreDecay(ctx)

	// Start cleanup goroutine
	go m.runCleanup(ctx)

	return nil
}

// Stop gracefully shuts down the module
func (m *Module) Stop() error {
	if m.cancel != nil {
		m.cancel()
	}

	// Clean up journal command if running
	if m.journalCmd != nil && m.journalCmd.Process != nil {
		m.journalCmd.Process.Kill()
	}

	// v1.48.0: Clean up file watcher commands
	for _, cmd := range m.fileWatcherCmds {
		if cmd != nil && cmd.Process != nil {
			cmd.Process.Kill()
		}
	}

	// Close EVE file if open
	if m.eveFile != nil {
		m.eveFile.Close()
	}

	m.mu.Lock()
	m.status.MarkStopped()
	m.mu.Unlock()

	// Publish module stop event with final stats
	stats := m.scorer.GetStats()
	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, ModuleName).
		WithMessage("Login monitor stopped").
		WithData("total_detections", stats.TotalDetections).
		WithData("total_bans", stats.TotalBans))

	return nil
}

// Status returns the current module status
func (m *Module) Status() module.Status {
	m.mu.RLock()
	defer m.mu.RUnlock()

	m.status.UpdateUptime()
	m.status.Extra["mode"] = string(m.mode)
	m.status.Extra["suricata_available"] = m.suricataAvail
	m.status.Extra["services"] = m.getServiceList()
	m.status.Extra["detectors"] = m.registry.Detectors()

	// Add scorer statistics
	stats := m.scorer.GetStats()
	m.status.Extra["total_detections"] = stats.TotalDetections
	m.status.Extra["total_bans"] = stats.TotalBans
	m.status.Extra["total_escalations"] = stats.TotalEscalations
	m.status.Extra["total_permanent"] = stats.TotalPermanent
	m.status.Extra["unique_ips"] = stats.UniqueIPs
	m.status.Extra["detections_ipv4"] = stats.DetectionsIPv4
	m.status.Extra["detections_ipv6"] = stats.DetectionsIPv6
	m.status.Extra["bans_ipv4"] = stats.BansIPv4
	m.status.Extra["bans_ipv6"] = stats.BansIPv6
	m.status.Extra["tracked_ips"] = m.scorer.TrackedIPs()
	m.status.Extra["detections_by_service"] = stats.DetectionsByService
	m.status.Extra["bans_by_service"] = stats.BansByService
	m.status.Extra["detections_by_reason"] = stats.DetectionsByReason
	m.status.Extra["bans_by_reason"] = stats.BansByReason

	return m.status
}

// loadConfig loads configuration from files
func (m *Module) loadConfig() error {
	configDir, _, _, _ := getLoginmonPaths()

	// Try to load main.conf
	mainConfig := filepath.Join(configDir, "main.conf")
	if data, err := os.ReadFile(mainConfig); err == nil {
		m.parseShellConfig(string(data))
	}

	// Try to load scorer.conf (scorer-specific settings)
	scorerConfig := filepath.Join(configDir, "scorer.conf")
	if data, err := os.ReadFile(scorerConfig); err == nil {
		m.parseShellConfig(string(data))
	}

	// Try to load main.conf.local for overrides
	localConfig := filepath.Join(configDir, "main.conf.local")
	if data, err := os.ReadFile(localConfig); err == nil {
		m.parseShellConfig(string(data))
	}

	// Try to load scorer.conf.local for overrides
	scorerLocalConfig := filepath.Join(configDir, "scorer.conf.local")
	if data, err := os.ReadFile(scorerLocalConfig); err == nil {
		m.parseShellConfig(string(data))
	}

	// Central override (nftban.conf.local — highest priority)
	cfg := nftbanconf.MustLoad()
	centralLocal := filepath.Join(cfg.ConfigDir, "nftban.conf.local")
	if data, err := os.ReadFile(centralLocal); err == nil {
		m.parseShellConfig(string(data))
	}

	// Rebuild scorer with loaded configuration
	m.scorer = detector.NewScorer(m.buildScorerConfig())

	return nil
}

// parseShellConfig parses shell-style KEY=VALUE configuration
func (m *Module) parseShellConfig(content string) {
	lines := strings.Split(content, "\n")
	for _, line := range lines {
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
		// Module settings
		case "LOGIN_ENABLED":
			m.config.Enabled = value == "true"
		case "LOGIN_MODE":
			m.mode = Mode(value)
		case "LOGIN_MAX_FAILED_ATTEMPTS":
			fmt.Sscanf(value, "%d", &m.config.MaxFailedAttempts)
		case "LOGIN_DEFAULT_BAN_DURATION":
			if d, err := time.ParseDuration(value + "s"); err == nil {
				m.config.MediumRiskDuration = d
			}

		// Scorer thresholds
		case "THRESHOLD_TEMP_BAN":
			fmt.Sscanf(value, "%d", &m.config.ThresholdTempBan)
		case "THRESHOLD_ESCALATE":
			fmt.Sscanf(value, "%d", &m.config.ThresholdEscalate)
		case "THRESHOLD_PERMANENT":
			fmt.Sscanf(value, "%d", &m.config.ThresholdPermanent)
		case "TEMP_BAN_DURATION":
			if d, err := time.ParseDuration(value); err == nil {
				m.config.TempBanDuration = d
			}
		case "SCORE_DECAY_INTERVAL":
			if d, err := time.ParseDuration(value); err == nil {
				m.config.ScoreDecayInterval = d
			}
		case "SCORE_DECAY_AMOUNT":
			fmt.Sscanf(value, "%d", &m.config.ScoreDecayAmount)
		case "IP_RETENTION_DURATION":
			if d, err := time.ParseDuration(value); err == nil {
				m.config.IPRetentionDuration = d
			}

		// SSH score deltas
		case "SSH_FAILED_PASSWORD_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.SSHFailedPassword = safeconv.ToInt16OrDefault(v, 10)
		case "SSH_INVALID_USER_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.SSHInvalidUser = safeconv.ToInt16OrDefault(v, 10)
		case "SSH_PREAUTH_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.SSHPreauth = safeconv.ToInt16OrDefault(v, 10)
		case "SSH_TOO_MANY_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.SSHTooMany = safeconv.ToInt16OrDefault(v, 10)
		case "SSH_ROOT_ATTEMPT_BONUS":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.SSHRootAttempt = safeconv.ToInt16OrDefault(v, 10)

		// Mail score deltas
		case "DOVECOT_AUTH_FAIL_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.DovecotAuthFail = safeconv.ToInt16OrDefault(v, 10)
		case "POSTFIX_SASL_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.PostfixSASL = safeconv.ToInt16OrDefault(v, 10)
		case "EXIM_AUTH_FAIL_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.EximAuthFail = safeconv.ToInt16OrDefault(v, 10)

		// FTP score deltas
		case "FTP_AUTH_FAIL_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.FTPAuthFail = safeconv.ToInt16OrDefault(v, 10)

		// Panel score deltas
		case "DIRECTADMIN_LOGIN_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.DirectAdminLogin = safeconv.ToInt16OrDefault(v, 10)
		case "CPANEL_LOGIN_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.CPanelLogin = safeconv.ToInt16OrDefault(v, 10)
		case "PLESK_LOGIN_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.PleskLogin = safeconv.ToInt16OrDefault(v, 10)

		// WordPress score deltas
		case "WORDPRESS_XMLRPC_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.WordPressXMLRPC = safeconv.ToInt16OrDefault(v, 10)
		case "WORDPRESS_WPLOGIN_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.WordPressWPLogin = safeconv.ToInt16OrDefault(v, 10)
		}
	}
}

// buildScorerConfig creates a ScorerConfig from the loaded Config
func (m *Module) buildScorerConfig() detector.ScorerConfig {
	return detector.ScorerConfig{
		ThresholdTempBan:      m.config.ThresholdTempBan,
		ThresholdEscalate:     m.config.ThresholdEscalate,
		ThresholdPermanent:    m.config.ThresholdPermanent,
		TempBanDuration:       m.config.TempBanDuration,
		EscalateDurations:     m.config.EscalateDurations,
		ScoreDecayInterval:    m.config.ScoreDecayInterval,
		ScoreDecayAmount:      m.config.ScoreDecayAmount,
		IPRetentionDuration:   m.config.IPRetentionDuration,
	}
}

// detectServices detects which services are installed
func (m *Module) detectServices() {
	services := []string{
		"sshd", "ssh",
		"dovecot",
		"postfix", "exim", "exim4",
		"pure-ftpd", "vsftpd", "proftpd",
		"apache2", "httpd", "nginx",
	}

	for _, svc := range services {
		if m.serviceExists(svc) {
			// Normalize service names
			switch svc {
			case "sshd", "ssh":
				m.detectedServices["ssh"] = true
			case "exim", "exim4":
				m.detectedServices["exim"] = true
			case "apache2", "httpd":
				m.detectedServices["apache"] = true
			default:
				m.detectedServices[svc] = true
			}
		}
	}

	// Check for DirectAdmin
	if _, err := os.Stat("/usr/local/directadmin"); err == nil {
		m.detectedServices["directadmin"] = true
	}

	// Check for cPanel
	if _, err := os.Stat("/usr/local/cpanel"); err == nil {
		m.detectedServices["cpanel"] = true
	}

	// Check for Plesk
	if _, err := os.Stat("/usr/local/psa"); err == nil {
		m.detectedServices["plesk"] = true
	}

	// Check for WordPress (look for wp-config.php)
	if m.detectedServices["apache"] || m.detectedServices["nginx"] {
		if files, _ := filepath.Glob("/var/www/*/wp-config.php"); len(files) > 0 {
			m.detectedServices["wordpress"] = true
		}
	}
}

// serviceExists checks if a service is installed
func (m *Module) serviceExists(name string) bool {
	// Check systemd
	cmd := exec.Command("systemctl", "list-unit-files", name+".service")
	if output, err := cmd.Output(); err == nil && strings.Contains(string(output), name) {
		return true
	}

	// Check SysV init
	if _, err := os.Stat("/etc/init.d/" + name); err == nil {
		return true
	}

	// Check binary
	if _, err := exec.LookPath(name); err == nil {
		return true
	}

	return false
}

// getServiceList returns list of detected services
func (m *Module) getServiceList() string {
	var services []string
	for svc := range m.detectedServices {
		services = append(services, svc)
	}
	return strings.Join(services, ",")
}

// checkSuricataAvailable checks if Suricata is available for login monitoring
func (m *Module) checkSuricataAvailable() bool {
	score := 0

	// Check binary
	if _, err := os.Stat(DefaultSuricataBin); err == nil {
		score++
	}

	// Check if service is running
	cmd := exec.Command("systemctl", "is-active", "suricata")
	if err := cmd.Run(); err == nil {
		score++
	}

	// Check if EVE file is fresh
	if info, err := os.Stat(DefaultEVEPath); err == nil {
		if time.Since(info.ModTime()).Seconds() < EVEFreshnessThreshold {
			score++
		}
	}

	return score >= 2
}

// detectMode determines which mode to use
func (m *Module) detectMode() Mode {
	switch m.mode {
	case ModeClassic:
		return ModeClassic
	case ModeSuricata:
		if m.suricataAvail {
			return ModeSuricata
		}
		return ModeClassic // Fallback
	case ModeHybrid:
		return ModeHybrid
	default: // Auto
		if m.suricataAvail {
			return ModeSuricata
		}
		return ModeClassic
	}
}

// runJournalWatcher watches journalctl for login failures
func (m *Module) runJournalWatcher(ctx context.Context) {
	// Build journalctl command
	m.journalCmd = exec.CommandContext(ctx, "journalctl",
		"-f",             // Follow mode
		"-n", "0",        // Don't show historical entries
		"--no-pager",
		"-o", "short-iso",
		"SYSLOG_FACILITY=4",  // Auth facility
		"SYSLOG_FACILITY=10", // Authpriv facility
	)

	stdout, err := m.journalCmd.StdoutPipe()
	if err != nil {
		m.status.RecordError(err)
		return
	}
	// CRITICAL: Close stdout pipe on exit to prevent FD/memory leak
	defer stdout.Close()

	if err := m.journalCmd.Start(); err != nil {
		m.status.RecordError(err)
		return
	}

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return
		default:
			m.processLine(scanner.Bytes())
		}
	}
}

// panelLogPaths maps detected panel services to their log file paths.
// These services log to their own files, NOT to journalctl/syslog.
// v1.48.0: Verified against real servers (srv2=DA, lab4=cPanel, lab2=Plesk)
var panelLogPaths = map[string][]string{
	"directadmin": {"/var/log/directadmin/login.log"},
	"cpanel":      {"/usr/local/cpanel/logs/access_log"},   // 401 on POST /login/
	"plesk":       {"/var/log/plesk/panel.log"},              // "[Action Log] Failed login attempt"
}

// startFileWatchers launches tail -F watchers for panel services
// that log to their own files instead of journalctl.
func (m *Module) startFileWatchers(ctx context.Context) {
	for service, paths := range panelLogPaths {
		if !m.detectedServices[service] {
			continue
		}
		for _, logPath := range paths {
			if _, err := os.Stat(logPath); err != nil {
				continue
			}
			go m.runFileWatcher(ctx, service, logPath)
		}
	}
}

// runFileWatcher tails a log file and feeds lines through the detector pipeline.
func (m *Module) runFileWatcher(ctx context.Context, service, logPath string) {
	cmd := exec.CommandContext(ctx, "tail", "-F", "-n", "0", logPath)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		m.status.RecordError(fmt.Errorf("file watcher %s: pipe: %w", service, err))
		return
	}
	defer stdout.Close()

	if err := cmd.Start(); err != nil {
		m.status.RecordError(fmt.Errorf("file watcher %s: start: %w", service, err))
		return
	}

	// Track for cleanup on Stop()
	m.mu.Lock()
	m.fileWatcherCmds = append(m.fileWatcherCmds, cmd)
	m.mu.Unlock()

	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStart, ModuleName).
		WithMessage(fmt.Sprintf("File watcher started: %s (%s)", service, logPath)))

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return
		default:
			m.processLine(scanner.Bytes())
		}
	}
}

// processLine processes a single log line using high-performance detector
func (m *Module) processLine(line []byte) {
	startTime := time.Now()

	// Use high-performance signal-based detection
	verdict, ok := m.registry.Detect(line)
	if !ok {
		return // No match - fast path (0 allocations)
	}

	m.status.RecordEvent()

	// Record detection metrics
	reasonName := detector.ReasonName[verdict.Reason]
	metrics.RecordLoginmonDetection(reasonName, verdict.Service)
	metrics.SetLoginmonTrackedIPs(m.scorer.TrackedIPs())

	// Record detection latency
	metrics.RecordLoginmonDetectionLatency(time.Since(startTime).Seconds())

	// Record in scorer and check for ban threshold
	banAction := m.scorer.RecordVerdict(verdict)
	if banAction != nil {
		m.triggerBan(banAction)
	} else {
		// Publish detection event (not yet banned)
		m.bus.Publish(eventbus.NewEvent(eventbus.EventLoginFailed, ModuleName).
			WithIP(verdict.IP.String()).
			WithUser(verdict.User).
			WithMessage(fmt.Sprintf("Login failure: %s", detector.ReasonName[verdict.Reason])).
			WithSeverity(eventbus.SeverityWarning).
			WithData("service", verdict.Service).
			WithData("reason", detector.ReasonName[verdict.Reason]).
			WithData("score_delta", verdict.ScoreDelta))
	}
}

// triggerBan initiates a ban based on scorer decision
func (m *Module) triggerBan(action *detector.BanAction) {
	// Determine severity based on duration
	severity := eventbus.SeverityCritical
	banType := "temporary"
	if action.Duration == 0 {
		banType = "permanent"
	}

	// Determine IP family
	family := "ipv4"
	if !action.IP.Is4() {
		family = "ipv6"
	}

	// Record ban metrics
	metrics.RecordLoginmonBan(family, action.Reason)
	metrics.RecordLoginmonScoreAtBan(float64(action.Score))
	metrics.RecordBan("loginmon", family)

	// Publish ban event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventBan, ModuleName).
		WithIP(action.IP.String()).
		WithMessage(fmt.Sprintf("Banning %s: score=%d reason=%s", action.IP, action.Score, action.Reason)).
		WithSeverity(severity).
		WithData("service", action.Service).
		WithData("reason", action.Reason).
		WithData("score", action.Score).
		WithData("duration", action.Duration.String()).
		WithData("ban_type", banType).
		WithData("is_new", action.IsNew))
}

// runEVEWatcher watches Suricata EVE JSON log for auth failures
func (m *Module) runEVEWatcher(ctx context.Context) {
	var err error
	m.eveFile, err = os.Open(DefaultEVEPath)
	if err != nil {
		m.status.RecordError(err)
		return
	}

	// Seek to end of file
	m.eveFile.Seek(0, io.SeekEnd)

	m.eveReader = bufio.NewReader(m.eveFile)

	ticker := time.NewTicker(constants.LoginmonEVEPollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.processEVELines()
		}
	}
}

// EVEEvent represents a Suricata EVE JSON event
type EVEEvent struct {
	Timestamp string `json:"timestamp"`
	EventType string `json:"event_type"`
	SrcIP     string `json:"src_ip"`
	DestIP    string `json:"dest_ip"`
	SrcPort   int    `json:"src_port"`
	DestPort  int    `json:"dest_port"`
	Alert     *struct {
		Action      string `json:"action"`
		Category    string `json:"category"`
		Signature   string `json:"signature"`
		SignatureID int    `json:"signature_id"`
	} `json:"alert,omitempty"`
	SSH *struct {
		Client string `json:"client"`
		Server string `json:"server"`
	} `json:"ssh,omitempty"`
}

// processEVELines processes new lines from EVE JSON log
func (m *Module) processEVELines() {
	for {
		line, err := m.eveReader.ReadBytes('\n')
		if err != nil {
			return // No more lines
		}

		var event EVEEvent
		if err := json.Unmarshal(line, &event); err != nil {
			continue
		}

		// Look for authentication-related alerts
		if event.Alert != nil {
			category := strings.ToLower(event.Alert.Category)
			signature := strings.ToLower(event.Alert.Signature)

			// Check for auth failure patterns
			if strings.Contains(category, "authentication") ||
				strings.Contains(signature, "brute") ||
				strings.Contains(signature, "failed") ||
				strings.Contains(signature, "login") {

				// Also try to detect from raw line using our detectors
				m.processLine(line)
			}
		}
	}
}

// handleExternalLoginEvent handles login events from other sources
func (m *Module) handleExternalLoginEvent(e eventbus.Event) {
	// External events are already processed, just log them
	m.status.RecordEvent()
}

// runScoreDecay periodically decays IP scores
func (m *Module) runScoreDecay(ctx context.Context) {
	ticker := time.NewTicker(constants.LoginmonScoreDecayInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.scorer.DecayScores()
		}
	}
}

// runCleanup periodically cleans up old IP entries
func (m *Module) runCleanup(ctx context.Context) {
	ticker := time.NewTicker(constants.LoginmonCleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = m.scorer.Cleanup() // Periodically clean stale IP entries
		}
	}
}

// Descriptor returns the module descriptor
func Descriptor() module.Descriptor {
	configDir, _, _, _ := getLoginmonPaths()
	return module.Descriptor{
		Name:        ModuleName,
		Version:     ModuleVersion,
		Description: "Login Monitor (High-Performance Signal-Based Detection)",
		Optional:    false,
		ConfigFile:  filepath.Join(configDir, "main.conf"),
	}
}
