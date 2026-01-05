// =============================================================================
// NFTBan v1.0 - Login Monitor Module (Pure Go Implementation)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: loginmon
// Purpose: Go module for login monitoring with dual-mode support
//
// Architecture:
// - Implements the module.Module interface for daemon integration
// - Dual-mode: Classic (journalctl) or Suricata (EVE JSON)
// - Publishes events to the central event bus
// - Runs log watchers as goroutines
//
// This module replaces fail2ban with intelligent, risk-based ban decisions
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
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/module"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

const (
	ModuleName    = "loginmon"
	ModuleVersion = "1.0.0"

	// Suricata paths (NFTBan alert-only output)
	DefaultEVEPath        = "/var/log/nftban/suricata/eve-alerts.json"
	DefaultSuricataBin    = "/usr/bin/suricata"
	EVEFreshnessThreshold = 60 // seconds

	// Detection intervals
	DefaultCheckInterval = 10 * time.Second
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

	// Configuration
	config *Config
	mode   Mode

	// Runtime state
	state           *LoginState
	suricataAvail   bool
	detectedServices map[string]bool

	// Log watchers
	journalCmd    *exec.Cmd
	eveFile       *os.File
	eveReader     *bufio.Reader

	// Statistics
	eventsProcessed int64
	bansTriggered   int64
	alertsSent      int64
}

// ServicePatterns contains regex patterns for detecting login failures
type ServicePatterns struct {
	SSH       *regexp.Regexp
	Dovecot   *regexp.Regexp
	Postfix   *regexp.Regexp
	DirectAdmin *regexp.Regexp
	PureFTPd  *regexp.Regexp
	WordPress *regexp.Regexp
	Generic   *regexp.Regexp
}

var patterns = ServicePatterns{
	// SSH: "Failed password for (user) from (ip)"
	SSH: regexp.MustCompile(`(?i)(?:sshd|ssh).*(?:Failed password|Invalid user|authentication failure).*from[:\s]+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})`),
	// Dovecot: "auth failed, (ip)"
	Dovecot: regexp.MustCompile(`(?i)dovecot.*(?:auth failed|authentication failure).*rip=(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})`),
	// Postfix SASL: "SASL LOGIN authentication failed.*from (hostname)[(ip)]"
	Postfix: regexp.MustCompile(`(?i)postfix.*SASL.*authentication failed.*\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]`),
	// DirectAdmin: "Failed login"
	DirectAdmin: regexp.MustCompile(`(?i)directadmin.*(?:FAILED LOGIN|Invalid Login).*IP=(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})`),
	// Pure-FTPd: "Authentication failed for user"
	PureFTPd: regexp.MustCompile(`(?i)pure-ftpd.*(?:Authentication failed|Login failed).*\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]`),
	// WordPress: "xmlrpc.php POST" or wp-login failures
	WordPress: regexp.MustCompile(`(?i)(?:POST /xmlrpc\.php|wp-login\.php.*failed).*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})`),
	// Generic: any authentication failure with IP
	Generic: regexp.MustCompile(`(?i)(?:authentication failure|failed login|invalid password).*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})`),
}

// New creates a new login monitor module
func New() *Module {
	return &Module{
		status:           module.NewStatus(ModuleName),
		config:           DefaultConfig(),
		mode:             ModeAuto,
		state:            NewLoginState(),
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
		WithMessage("Login monitor started").
		WithData("mode", string(m.mode)).
		WithData("services", m.getServiceList()))

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

	// Start state cleanup goroutine
	go m.runStateCleanup(ctx)

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

	// Close EVE file if open
	if m.eveFile != nil {
		m.eveFile.Close()
	}

	m.mu.Lock()
	m.status.MarkStopped()
	m.mu.Unlock()

	// Publish module stop event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, ModuleName).
		WithMessage("Login monitor stopped"))

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
	m.status.Extra["events_processed"] = m.eventsProcessed
	m.status.Extra["bans_triggered"] = m.bansTriggered
	m.status.Extra["alerts_sent"] = m.alertsSent
	m.status.Extra["tracked_users"] = len(m.state.Users)
	m.status.Extra["tracked_ips"] = len(m.state.IPs)

	return m.status
}

// loadConfig loads configuration from files
func (m *Module) loadConfig() error {
	configDir, _, _, _ := getLoginmonPaths()

	// Try to load main.conf
	mainConfig := filepath.Join(configDir, "main.conf")
	if data, err := os.ReadFile(mainConfig); err == nil {
		// Parse shell-style config
		m.parseShellConfig(string(data))
	}

	// Try to load main.conf.local for overrides
	localConfig := filepath.Join(configDir, "main.conf.local")
	if data, err := os.ReadFile(localConfig); err == nil {
		m.parseShellConfig(string(data))
	}

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
		}
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
		"-f",              // Follow mode
		"-n", "0",         // Don't show historical entries
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
			m.processJournalLine(scanner.Text())
		}
	}
}

// processJournalLine processes a single journal line
func (m *Module) processJournalLine(line string) {
	m.mu.Lock()
	m.eventsProcessed++
	m.mu.Unlock()

	var ip, service string

	// Try each pattern
	if match := patterns.SSH.FindStringSubmatch(line); len(match) > 1 {
		ip = match[1]
		service = "ssh"
	} else if match := patterns.Dovecot.FindStringSubmatch(line); len(match) > 1 {
		ip = match[1]
		service = "dovecot"
	} else if match := patterns.Postfix.FindStringSubmatch(line); len(match) > 1 {
		ip = match[1]
		service = "postfix"
	} else if match := patterns.DirectAdmin.FindStringSubmatch(line); len(match) > 1 {
		ip = match[1]
		service = "directadmin"
	} else if match := patterns.PureFTPd.FindStringSubmatch(line); len(match) > 1 {
		ip = match[1]
		service = "pure-ftpd"
	} else if match := patterns.Generic.FindStringSubmatch(line); len(match) > 1 {
		ip = match[1]
		service = "unknown"
	}

	if ip != "" {
		m.handleLoginFailure(ip, service, "classic")
	}
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

	ticker := time.NewTicker(100 * time.Millisecond)
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
		Action    string `json:"action"`
		Category  string `json:"category"`
		Signature string `json:"signature"`
		SignatureID int  `json:"signature_id"`
	} `json:"alert,omitempty"`
	SSH *struct {
		Client  string `json:"client"`
		Server  string `json:"server"`
	} `json:"ssh,omitempty"`
}

// processEVELines processes new lines from EVE JSON log
func (m *Module) processEVELines() {
	for {
		line, err := m.eveReader.ReadString('\n')
		if err != nil {
			return // No more lines
		}

		m.mu.Lock()
		m.eventsProcessed++
		m.mu.Unlock()

		var event EVEEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
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
				m.handleLoginFailure(event.SrcIP, "suricata", "suricata")
			}
		}
	}
}

// handleLoginFailure processes a detected login failure
func (m *Module) handleLoginFailure(ip, service, source string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Update IP profile
	profile, exists := m.state.IPs[ip]
	if !exists {
		profile = &IPProfile{
			IP:        ip,
			Users:     make(map[string]time.Time),
			FirstSeen: time.Now(),
		}
		m.state.IPs[ip] = profile
	}

	profile.FailedLogins++
	profile.LastActivity = time.Now()

	m.status.RecordEvent()

	// Check if threshold exceeded
	if profile.FailedLogins >= m.config.MaxFailedAttempts {
		m.triggerBan(ip, service, source, profile.FailedLogins)
	} else {
		// Publish alert event
		m.alertsSent++
		m.bus.Publish(eventbus.NewEvent(eventbus.EventLoginFailed, ModuleName).
			WithIP(ip).
			WithMessage(fmt.Sprintf("Login failure detected from %s via %s", service, source)).
			WithSeverity(eventbus.SeverityWarning).
			WithData("service", service).
			WithData("failures", profile.FailedLogins))
	}
}

// triggerBan initiates a ban for an IP
func (m *Module) triggerBan(ip, service, source string, failures int) {
	m.bansTriggered++

	// Calculate ban duration based on failure count
	duration := m.config.MediumRiskDuration
	if failures >= m.config.MaxFailedAttempts*2 {
		duration = m.config.HighRiskDuration
	}

	// Publish ban event
	m.bus.Publish(eventbus.NewEvent(eventbus.EventBan, ModuleName).
		WithIP(ip).
		WithMessage(fmt.Sprintf("Banning %s: %d login failures via %s", ip, failures, service)).
		WithSeverity(eventbus.SeverityCritical).
		WithData("service", service).
		WithData("source", source).
		WithData("failures", failures).
		WithData("duration", duration.String()).
		WithData("reason", "login_brute_force"))

	// Reset failure count after ban
	if profile, exists := m.state.IPs[ip]; exists {
		profile.FailedLogins = 0
	}
}

// handleExternalLoginEvent handles login events from other sources
func (m *Module) handleExternalLoginEvent(e eventbus.Event) {
	if e.IP != "" {
		m.handleLoginFailure(e.IP, e.Source, "external")
	}
}

// runStateCleanup periodically cleans up old state entries
func (m *Module) runStateCleanup(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.cleanupState()
		}
	}
}

// cleanupState removes old entries from state
func (m *Module) cleanupState() {
	m.mu.Lock()
	defer m.mu.Unlock()

	cutoff := time.Now().Add(-m.config.ProfileRetention)

	// Clean up IP profiles
	for ip, profile := range m.state.IPs {
		if profile.LastActivity.Before(cutoff) {
			delete(m.state.IPs, ip)
		}
	}

	// Clean up user profiles
	for user, profile := range m.state.Users {
		if profile.LastLoginTime.Before(cutoff) {
			delete(m.state.Users, user)
		}
	}
}

// Descriptor returns the module descriptor
func Descriptor() module.Descriptor {
	configDir, _, _, _ := getLoginmonPaths()
	return module.Descriptor{
		Name:        ModuleName,
		Version:     ModuleVersion,
		Description: "Login Monitor (Dual-Mode: Classic/Suricata) - Replaces fail2ban",
		Optional:    false,
		ConfigFile:  filepath.Join(configDir, "main.conf"),
	}
}
