// =============================================================================
// NFTBan v1.20.0 - HTTP Bot Guard: Configuration Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Load bot guard configuration from /etc/nftban/conf.d/botguard/
//
// meta:name="botguard_config"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="Configuration loader for HTTP bot guard module"
// meta:inventory.files="config.go"
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
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds all bot guard configuration.
type Config struct {
	// Module control
	Enabled bool

	// Classification loop intervals
	LoopInterval         time.Duration // Normal: 60s
	LoopPressureInterval time.Duration // Under pressure: 40s

	// Hysteresis thresholds (per IP connection count)
	TripConn      int // Start analyzing (default 200)
	ClearConn     int // Stop analyzing (default 150)
	EmergencyConn int // Immediate block (default 500)

	// Kernel suspect marking config (informational — actual values in nft rules)
	SuspectRate    string        // e.g. "30/second"
	SuspectBurst   int           // e.g. 60
	SuspectTimeout time.Duration // e.g. 5m

	// TTLs for classification sets
	AllowTTL     time.Duration // 24h initial
	BanTTL       time.Duration // 96h
	GreyTTL      time.Duration // 30m
	EmergencyTTL time.Duration // 30m
	PendingTTL   time.Duration // 60s

	// Auto-tuning
	AutoTune bool

	// Batch integration
	BatchSignalFile string
	BatchInterval   time.Duration

	// Logging
	LogLevel     string
	LogDecisions bool
}

// DefaultConfig returns production-safe defaults.
func DefaultConfig() *Config {
	return &Config{
		Enabled:              false, // Disabled until explicitly enabled
		LoopInterval:         60 * time.Second,
		LoopPressureInterval: 40 * time.Second,
		TripConn:             200,
		ClearConn:            150,
		EmergencyConn:        500,
		SuspectRate:          "30/second",
		SuspectBurst:         60,
		SuspectTimeout:       5 * time.Minute,
		AllowTTL:             24 * time.Hour,
		BanTTL:               96 * time.Hour,
		GreyTTL:              30 * time.Minute,
		EmergencyTTL:         30 * time.Minute,
		PendingTTL:           60 * time.Second,
		AutoTune:             true,
		BatchSignalFile:      "/var/lib/nftban/botguard/batch_signals.jsonl",
		BatchInterval:        10 * time.Minute,
		LogLevel:             "INFO",
		LogDecisions:         true,
	}
}

// LoadConfig reads configuration from a shell-style config file.
// Supports KEY="VALUE" format (same as all NFTBan config files).
func LoadConfig(path string) (*Config, error) {
	cfg := DefaultConfig()

	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			// No config file = use defaults (module disabled)
			return cfg, nil
		}
		return nil, fmt.Errorf("open config %s: %w", path, err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		key, value, ok := parseConfigLine(line)
		if !ok {
			continue
		}

		switch key {
		case "HTTP_BOTGUARD_ENABLED":
			cfg.Enabled = parseBool(value)
		case "HTTP_BOT_FAST_LOOP_INTERVAL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.LoopInterval = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_FAST_LOOP_PRESSURE_INTERVAL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.LoopPressureInterval = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_TRIP_CONN":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.TripConn = v
			}
		case "HTTP_BOT_CLEAR_CONN":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.ClearConn = v
			}
		case "HTTP_BOT_EMERGENCY_CONN":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.EmergencyConn = v
			}
		case "HTTP_BOT_SUSPECT_RATE":
			if value != "" {
				cfg.SuspectRate = value
			}
		case "HTTP_BOT_SUSPECT_BURST":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.SuspectBurst = v
			}
		case "HTTP_BOT_SUSPECT_TIMEOUT":
			if d, err := parseDuration(value); err == nil {
				cfg.SuspectTimeout = d
			}
		case "HTTP_BOT_ALLOW_TTL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.AllowTTL = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_BAN_TTL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.BanTTL = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_GREY_TTL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.GreyTTL = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_EMERGENCY_TTL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.EmergencyTTL = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_PENDING_TTL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.PendingTTL = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_AUTO_TUNE":
			cfg.AutoTune = parseBool(value)
		case "HTTP_BOT_BATCH_SIGNAL_FILE":
			if value != "" {
				cfg.BatchSignalFile = value
			}
		case "HTTP_BOT_BATCH_INTERVAL":
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.BatchInterval = time.Duration(v) * time.Second
			}
		case "HTTP_BOT_LOG_LEVEL":
			if value != "" {
				cfg.LogLevel = strings.ToUpper(value)
			}
		case "HTTP_BOT_LOG_DECISIONS":
			cfg.LogDecisions = parseBool(value)
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading config %s: %w", path, err)
	}

	return cfg, nil
}

// parseConfigLine extracts KEY and VALUE from a KEY="VALUE" line.
func parseConfigLine(line string) (key, value string, ok bool) {
	idx := strings.IndexByte(line, '=')
	if idx < 1 {
		return "", "", false
	}
	key = strings.TrimSpace(line[:idx])
	value = strings.TrimSpace(line[idx+1:])
	// Remove surrounding quotes
	value = strings.Trim(value, `"'`)
	return key, value, true
}

// parseBool converts shell-style boolean strings.
func parseBool(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "true", "yes", "1", "on":
		return true
	default:
		return false
	}
}

// parseDuration parses nftables-style duration strings (e.g. "5m", "1h", "30s").
func parseDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty duration")
	}
	// Try Go duration first
	if d, err := time.ParseDuration(s); err == nil {
		return d, nil
	}
	// Try plain seconds
	if v, err := strconv.Atoi(s); err == nil {
		return time.Duration(v) * time.Second, nil
	}
	return 0, fmt.Errorf("invalid duration: %s", s)
}
