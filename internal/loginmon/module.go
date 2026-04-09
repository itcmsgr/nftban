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
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/loginmon/detector"
	"github.com/itcmsgr/nftban/internal/loginmon/distroconf"
	daparser "github.com/itcmsgr/nftban/internal/loginmon/pipeline/parser/directadmin"
	eximparser "github.com/itcmsgr/nftban/internal/loginmon/pipeline/parser/exim"
	pipelineRuntime "github.com/itcmsgr/nftban/internal/loginmon/pipeline/runtime"
	pipelineSource "github.com/itcmsgr/nftban/internal/loginmon/pipeline/source"
	pipelineWatcher "github.com/itcmsgr/nftban/internal/loginmon/pipeline/watcher"
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

	// BUG-15: central distro config loader (single source of truth for log paths)
	// Loaded once at Init(); nil means loader unavailable (parser falls through
	// to authoritative tool query, then hard-coded fallback list).
	distroConf *distroconf.Loader

	// Log watchers
	journalCmd *exec.Cmd
	eveFile    *os.File
	eveReader  *bufio.Reader

	// v1.48.0: File watchers for services that don't log to journalctl
	// (DirectAdmin, cPanel, Plesk use their own log files)
	fileWatcherCmds []*exec.Cmd

	// v1.80 Phase B: Go pipeline (runs alongside legacy when PipelineEnabled=true)
	pipeline *pipelineRuntime.Pipeline
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

	// BUG-15: load central distro config (single source of truth for log paths).
	// Soft failure: if the loader can't be constructed, m.distroConf stays nil
	// and parser path resolution falls through to authoritative tools and the
	// hard-coded fallback lists. The doctor surfaces the loader failure as a
	// warning, not an error.
	if loader, err := distroconf.Load(distroconf.DefaultDir); err == nil {
		m.distroConf = loader
		log.Printf("[LOGINMON] distroconf loaded: distro=%s conf=%s family=%s",
			loader.DistroID(), loader.ConfPath(), loader.Family())
	} else {
		log.Printf("[LOGINMON] distroconf unavailable: %v (parsers will fall through to authoritative tools and fallback)", err)
	}

	// Detect available services
	m.detectServices()

	// Detect Suricata availability
	m.suricataAvail = m.checkSuricataAvailable()

	// Determine operating mode
	m.mode = m.detectMode()

	m.status.Enabled = m.config.Enabled

	// v1.80 Phase B: initialize Go pipeline if feature flag is enabled.
	// The pipeline runs ALONGSIDE the legacy detector — both produce events,
	// and the pipeline's internal dedup prevents double-counting. The legacy
	// path is still the primary; the pipeline is observe-only in Phase B.
	if m.config.PipelineEnabled {
		m.initPipeline()
	}

	return nil
}

// initPipeline creates and registers sources/watchers/parsers for the Go
// pipeline. Only DirectAdmin is wired in Phase B.
func (m *Module) initPipeline() {
	m.pipeline = pipelineRuntime.NewPipeline(pipelineRuntime.PipelineOptions{})

	// DirectAdmin login.log
	if m.detectedServices["directadmin"] {
		daLoginSrc := pipelineSource.NewFileSource(pipelineSource.FileSourceOptions{
			Name:      "directadmin",
			Service:   "directadmin_login",
			DistroKey: "directadmin_login_log",
			Loader:    m.distroConf,
			Fallback:  panelLogPaths["directadmin"],
		})

		if daLoginSrc.Descriptor().State == pipelineSource.StateActive ||
			daLoginSrc.Descriptor().State == pipelineSource.StateStale {
			w := pipelineWatcher.NewPollingWatcher(pipelineWatcher.PollingWatcherOptions{
				Source: "directadmin",
				Path:   daLoginSrc.Descriptor().Path,
			})
			p := daparser.New()

			if err := m.pipeline.Register(pipelineRuntime.Registration{
				Source:  daLoginSrc,
				Watcher: w,
				Parser:  p,
			}); err != nil {
				log.Printf("[LOGINMON] pipeline: DA registration failed: %v", err)
			} else {
				log.Printf("[LOGINMON] pipeline: DA registered: path=%s resolved_by=%s",
					daLoginSrc.Descriptor().Path, daLoginSrc.Descriptor().ResolvedBy)
			}
		} else {
			log.Printf("[LOGINMON] pipeline: DA source state=%s, skipping registration",
				daLoginSrc.Descriptor().State)
		}
	}

	// Exim mainlog (Phase C)
	if m.detectedServices["exim"] {
		eximSrc := pipelineSource.NewFileSource(pipelineSource.FileSourceOptions{
			Name:      "exim",
			Service:   "exim_smtp",
			DistroKey: "exim_log",
			Loader:    m.distroConf,
			Fallback:  mailLogPaths["exim"],
		})

		if eximSrc.Descriptor().State == pipelineSource.StateActive ||
			eximSrc.Descriptor().State == pipelineSource.StateStale {
			w := pipelineWatcher.NewPollingWatcher(pipelineWatcher.PollingWatcherOptions{
				Source: "exim",
				Path:   eximSrc.Descriptor().Path,
			})
			p := eximparser.New()

			if err := m.pipeline.Register(pipelineRuntime.Registration{
				Source:  eximSrc,
				Watcher: w,
				Parser:  p,
			}); err != nil {
				log.Printf("[LOGINMON] pipeline: Exim registration failed: %v", err)
			} else {
				log.Printf("[LOGINMON] pipeline: Exim registered: path=%s resolved_by=%s",
					eximSrc.Descriptor().Path, eximSrc.Descriptor().ResolvedBy)
			}
		} else {
			log.Printf("[LOGINMON] pipeline: Exim source state=%s, skipping",
				eximSrc.Descriptor().State)
		}
	}

	log.Printf("[LOGINMON] pipeline: initialized (PipelineEnabled=true)")
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

	// v1.80 Phase B: start Go pipeline (if initialized)
	if m.pipeline != nil {
		if err := m.pipeline.Start(ctx); err != nil {
			log.Printf("[LOGINMON] pipeline: start failed: %v", err)
		} else {
			log.Printf("[LOGINMON] pipeline: started (dual-run mode)")
		}
	}

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

	// v1.80: stop Go pipeline
	if m.pipeline != nil {
		if err := m.pipeline.Stop(); err != nil {
			log.Printf("[LOGINMON] pipeline: stop error: %v", err)
		}
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
		case "PIPELINE_ENABLED":
			m.config.PipelineEnabled = value == "true"
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
		case "DOVECOT_PAM_FAIL_SCORE":
			var v int
			fmt.Sscanf(value, "%d", &v)
			m.config.DovecotPamFail = safeconv.ToInt16OrDefault(v, 10)

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

// mailLogPaths maps mail services to their log file paths.
// Mail services (Exim, Dovecot, Postfix) log to plain files, NOT journalctl.
// v1.69.0: Verified against lab (Debian 13), lab2 (Ubuntu 24.04/Plesk),
//          lab4 (AlmaLinux 9/cPanel), srv2 (AlmaLinux 9/DirectAdmin).
// Zero journal entries for SYSLOG_FACILITY=4+10 from mail on all 4 servers.
var mailLogPaths = map[string][]string{
	"exim": {
		"/var/log/exim_mainlog",  // cPanel (EL) — BUG-17: was missing
		"/var/log/exim/mainlog",  // DirectAdmin (EL9)
		"/var/log/exim4/mainlog", // Debian/Ubuntu
	},
	"dovecot": {
		"/var/log/maillog",   // EL9, Ubuntu via rsyslog
		"/var/log/mail.log",  // Debian default
		"/var/log/secure",    // EL9 PAM auth (dovecot:auth)
		"/var/log/auth.log",  // Debian/Ubuntu PAM auth
	},
	"postfix": {
		"/var/log/maillog",  // EL9, Ubuntu via rsyslog
		"/var/log/mail.log", // Debian default
	},
}

// resolveSourcePath implements the BUG-4/BUG-12/BUG-15 layered resolution
// order for any parser source:
//
//  1. distroconf.Resolve(key)            ← central truth surface (BUG-15)
//  2. authorityFn() (optional)           ← e.g. `exim -bP log_file_path`
//  3. ordered hard-coded fallback list   ← last-resort safety net
//  4. ""                                 ← MISSING (caller does not start watcher)
//
// Every successful resolution emits exactly one [LOGINMON] init line that
// records the chosen path AND the resolution origin, satisfying Rule 1 of
// the v1.79.2 truth foundation plan: no parser may bypass distroconf, and
// every binding must be observable in journald.
//
// Returns ("", false) if all layers fail (MISSING). Returns ("", true) if
// the distroconf marks the source as not-applicable on this distro (DISABLED;
// caller skips silently with no warning).
//
// authorityFn may be nil for sources with no authoritative tool query
// (e.g. dovecot, directadmin). authorityName is the human-readable label
// used in the init log line ("exim -bP", "postconf -h maillog_file", "").
func (m *Module) resolveSourcePath(
	service, key string,
	authorityFn func() (string, error),
	authorityName string,
	fallback []string,
) (path string, naSkip bool) {
	// Layer 1: distroconf
	r := m.distroConf.Resolve(key) // safe on nil receiver — returns LoaderUnavailable
	switch r.Outcome {
	case distroconf.Resolved:
		if _, err := os.Stat(r.Path); err == nil {
			log.Printf("[LOGINMON] %s: %s=%s resolved_by=distroconf distro=%s",
				service, key, r.Path, r.DistroID)
			return r.Path, false
		}
		log.Printf("[LOGINMON] %s: distroconf path %s not on disk (%s); falling through",
			service, r.Path, r.Reason)
		// fall through to layer 2
	case distroconf.NotApplicable:
		log.Printf("[LOGINMON] %s: state=DISABLED reason=%s", service, r.Reason)
		return "", true
	case distroconf.Absent:
		if authorityFn != nil {
			log.Printf("[LOGINMON] %s: distroconf=absent (%s); trying authoritative tool", service, r.Reason)
		} else {
			log.Printf("[LOGINMON] %s: distroconf=absent (%s); trying fallback", service, r.Reason)
		}
	case distroconf.LoaderUnavailable:
		if authorityFn != nil {
			log.Printf("[LOGINMON] %s: distroconf=unavailable; trying authoritative tool", service)
		} else {
			log.Printf("[LOGINMON] %s: distroconf=unavailable; trying fallback", service)
		}
	}

	// Layer 2: authoritative tool query (optional)
	if authorityFn != nil {
		if p, err := authorityFn(); err == nil && p != "" {
			if _, err := os.Stat(p); err == nil {
				log.Printf("[LOGINMON] %s: %s=%s resolved_by=authority(%s)", service, key, p, authorityName)
				return p, false
			}
			log.Printf("[LOGINMON] %s: authority returned %s but file missing; falling through", service, p)
		} else if err != nil {
			log.Printf("[LOGINMON] %s: authority probe failed: %v", service, err)
		}
	}

	// Layer 3: hard-coded fallback list (preserves legacy behavior)
	for _, p := range fallback {
		if _, err := os.Stat(p); err == nil {
			log.Printf("[LOGINMON] %s: %s=%s resolved_by=fallback warning=hardcoded_probe", service, key, p)
			return p, false
		}
	}

	// Layer 4: MISSING
	log.Printf("[LOGINMON] %s: state=MISSING reason=no candidate path resolved (distroconf, authority, fallback all failed)", service)
	return "", false
}

// resolveEximLogPath is the BUG-4 entry point: layered resolution for exim_log
// using `exim -bP log_file_path` as the authoritative tool.
func (m *Module) resolveEximLogPath() (path string, naSkip bool) {
	return m.resolveSourcePath("exim", "exim_log", queryEximLogPath, "exim -bP", mailLogPaths["exim"])
}

// resolvePostfixLogPath is the BUG-12 entry point: layered resolution for
// maillog using `postconf -h maillog_file` as the authoritative tool.
// Postfix and dovecot share the maillog key on most distros; deduplication
// happens in startFileWatchers.
func (m *Module) resolvePostfixLogPath() (path string, naSkip bool) {
	return m.resolveSourcePath("postfix", "maillog", queryPostfixMaillogPath, "postconf -h maillog_file", mailLogPaths["postfix"])
}

// resolveDovecotLogPath is the dovecot entry point: layered resolution for
// dovecot_log. Dovecot has no authoritative tool query (it does not expose
// its log path via CLI), so layer 2 is skipped. Distroconf or fallback only.
func (m *Module) resolveDovecotLogPath() (path string, naSkip bool) {
	return m.resolveSourcePath("dovecot", "dovecot_log", nil, "", mailLogPaths["dovecot"])
}

// resolveDirectAdminLoginLogPath is the BUG-2 entry point (login.log half):
// layered resolution for directadmin_login_log. No authoritative tool;
// distroconf or fallback only. Returns DISABLED on Debian family (n/a literal).
func (m *Module) resolveDirectAdminLoginLogPath() (path string, naSkip bool) {
	return m.resolveSourcePath("directadmin", "directadmin_login_log", nil, "", panelLogPaths["directadmin"])
}

// resolveDirectAdminSecurityLogPath is the BUG-2 entry point (security.log half):
// layered resolution for directadmin_security_log. This is the second DA source
// added by the BUG-2 fix — DA's BFM logs failed logins here, and the existing
// parser was missing it entirely. Returns DISABLED on Debian family.
func (m *Module) resolveDirectAdminSecurityLogPath() (path string, naSkip bool) {
	return m.resolveSourcePath("directadmin", "directadmin_security_log", nil, "",
		[]string{"/var/log/directadmin/security.log"})
}

// queryEximLogPath runs `exim -bP log_file_path` and parses the output.
// Returns the resolved path or an error. Empty path is returned without error
// if the binary is missing (which is expected on hosts where exim is not
// installed at all — caller should handle as Absent).
func queryEximLogPath() (string, error) {
	exim, err := exec.LookPath("exim")
	if err != nil {
		return "", nil // not installed; not an error
	}
	// #nosec G204 -- exim path comes from PATH lookup, not user input.
	// Arguments are hard-coded constants. This is a system tool query, not user dispatch.
	cmd := exec.Command(exim, "-bP", "log_file_path")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("exim -bP failed: %w", err)
	}
	// Output format: "log_file_path = /var/log/exim/main_%slog"
	// or sometimes just "/var/log/exim/main_%slog" — handle both.
	line := strings.TrimSpace(string(out))
	if eq := strings.IndexByte(line, '='); eq >= 0 {
		line = strings.TrimSpace(line[eq+1:])
	}
	// Exim's path may contain "%slog" which expands at runtime to mainlog/rejectlog/paniclog.
	// We want the mainlog form for our parser.
	line = strings.ReplaceAll(line, "%slog", "mainlog")
	if line == "" {
		return "", fmt.Errorf("exim -bP returned empty path")
	}
	return line, nil
}

// queryPostfixMaillogPath runs `postconf -h maillog_file` and parses the output.
// Returns the resolved path or an error. Empty path is returned without error
// if postconf is missing (caller should handle as Absent — most postfix
// installations log via syslog and do not set maillog_file). An empty string
// is also returned if the directive is unset, which is the common case.
func queryPostfixMaillogPath() (string, error) {
	postconf, err := exec.LookPath("postconf")
	if err != nil {
		return "", nil // not installed; not an error
	}
	// #nosec G204 -- postconf path comes from PATH lookup, not user input.
	// Arguments are hard-coded constants. This is a system tool query, not user dispatch.
	cmd := exec.Command(postconf, "-h", "maillog_file")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("postconf -h maillog_file failed: %w", err)
	}
	line := strings.TrimSpace(string(out))
	// Empty result means maillog_file directive is unset — postfix is logging
	// via syslog. Caller falls through to fallback paths.
	return line, nil
}

// startFileWatchers launches tail -F watchers for services
// that log to their own files instead of journalctl.
//
// All parser sources resolve their log paths through the layered resolver
// (resolveSourcePath) per Rule 1 of the v1.79.2 truth foundation plan:
// NO parser may bypass distroconf.
//
// Resolution order for every source:
//
//  1. distroconf.Resolve(<key>)         ← central truth surface
//  2. authoritative tool (if defined)   ← e.g. exim -bP, postconf -h
//  3. ordered hard-coded fallback list  ← legacy safety net
//  4. ""                                ← MISSING (watcher not started)
//
// Every binding emits a [LOGINMON] init line in journald that records the
// chosen path AND the resolution origin, so coverage is observable.
func (m *Module) startFileWatchers(ctx context.Context) {
	watchedPaths := make(map[string]bool) // dedup shared paths (e.g. dovecot+postfix on /var/log/maillog)

	startWatcher := func(service, path string) {
		if path == "" || watchedPaths[path] {
			return
		}
		watchedPaths[path] = true
		go m.runFileWatcher(ctx, service, path)
	}

	// === BUG-4: exim ===
	if m.detectedServices["exim"] {
		if p, na := m.resolveEximLogPath(); !na {
			startWatcher("exim", p)
		}
	}

	// === BUG-12: postfix ===
	if m.detectedServices["postfix"] {
		if p, na := m.resolvePostfixLogPath(); !na {
			startWatcher("postfix", p)
		}
	}

	// === dovecot ===
	if m.detectedServices["dovecot"] {
		if p, na := m.resolveDovecotLogPath(); !na {
			startWatcher("dovecot", p)
		}
	}

	// === BUG-2: directadmin (login.log + security.log, both via distroconf) ===
	if m.detectedServices["directadmin"] {
		if p, na := m.resolveDirectAdminLoginLogPath(); !na {
			startWatcher("directadmin", p)
		}
		if p, na := m.resolveDirectAdminSecurityLogPath(); !na {
			startWatcher("directadmin", p)
		}
	}

	// === Other panel services (cPanel, Plesk) — still on legacy hard-coded list ===
	// These have no distroconf keys yet; they remain on the legacy resolution
	// path until added to the BUG-14 schema in a follow-up PR.
	for service, paths := range panelLogPaths {
		if service == "directadmin" {
			continue // handled above via layered resolver
		}
		if !m.detectedServices[service] {
			continue
		}
		for _, logPath := range paths {
			if _, err := os.Stat(logPath); err != nil {
				continue
			}
			startWatcher(service, logPath)
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
