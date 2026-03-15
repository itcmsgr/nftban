// =============================================================================
// NFTBan v1.21.0 - HTTP Bot Guard: Configuration Loader
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
	"path/filepath"
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

	// FCrDNS verification
	VerifyWorkers    int           // Max concurrent DNS workers (default 8)
	VerifyRateLimit  int           // Max new lookups per second (default 10)
	VerifyTimeout    time.Duration // Timeout per DNS lookup (default 3s)
	VerifyCacheTTL   time.Duration // Positive cache TTL (default 24h)
	VerifyNegTTL     time.Duration // Negative cache TTL (default 1h)

	// Crawler config files
	AllowedCrawlersFile string
	DeniedCrawlersFile  string

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
		VerifyWorkers:        8,
		VerifyRateLimit:      10,
		VerifyTimeout:        3 * time.Second,
		VerifyCacheTTL:       24 * time.Hour,
		VerifyNegTTL:         1 * time.Hour,
		AllowedCrawlersFile:  "/etc/nftban/conf.d/botguard/allowed_crawlers.conf",
		DeniedCrawlersFile:   "/etc/nftban/conf.d/botguard/denied_crawlers.conf",
		LogLevel:             "INFO",
		LogDecisions:         true,
	}
}

// LoadConfig reads configuration with the standard NFTBan override chain:
//   1. main.conf            — package defaults
//   2. main.conf.local      — user overrides (survive package updates)
//   3. nftban.conf.local    — central override (highest priority)
//
// Each file uses KEY="VALUE" format. Later files override earlier ones.
func LoadConfig(path string) (*Config, error) {
	cfg := DefaultConfig()

	// 1. Load main.conf
	if err := applyConfigFile(cfg, path); err != nil {
		return nil, err
	}

	// 2. Load main.conf.local (user overrides)
	localPath := path + ".local"
	if err := applyConfigFile(cfg, localPath); err != nil {
		return nil, err
	}

	// 3. Load central override (nftban.conf.local — highest priority)
	// configDir is two levels up: conf.d/botguard/main.conf → conf.d → /etc/nftban
	configDir := filepath.Dir(filepath.Dir(path))
	centralLocal := filepath.Join(configDir, "nftban.conf.local")
	if err := applyConfigFile(cfg, centralLocal); err != nil {
		return nil, err
	}

	return cfg, nil
}

// applyConfigFile reads a single config file and applies its values to cfg.
// Missing files are silently ignored (not an error).
func applyConfigFile(cfg *Config, path string) error {
	f, err := os.Open(filepath.Clean(path)) // #nosec G304 -- path from /etc/nftban/conf.d/ (trusted config dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("open config %s: %w", path, err)
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

		applyConfigKey(cfg, key, value)
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("reading config %s: %w", path, err)
	}

	return nil
}

// applyConfigKey applies a single KEY=VALUE pair to the config.
func applyConfigKey(cfg *Config, key, value string) {
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
	case "HTTP_BOT_VERIFY_WORKERS":
		if v, err := strconv.Atoi(value); err == nil && v > 0 && v <= 32 {
			cfg.VerifyWorkers = v
		}
	case "HTTP_BOT_VERIFY_RATE_LIMIT":
		if v, err := strconv.Atoi(value); err == nil && v > 0 {
			cfg.VerifyRateLimit = v
		}
	case "HTTP_BOT_VERIFY_TIMEOUT":
		if d, err := parseDuration(value); err == nil {
			cfg.VerifyTimeout = d
		}
	case "HTTP_BOT_VERIFY_CACHE_TTL":
		if v, err := strconv.Atoi(value); err == nil && v > 0 {
			cfg.VerifyCacheTTL = time.Duration(v) * time.Second
		}
	case "HTTP_BOT_VERIFY_NEG_TTL":
		if v, err := strconv.Atoi(value); err == nil && v > 0 {
			cfg.VerifyNegTTL = time.Duration(v) * time.Second
		}
	case "HTTP_BOT_ALLOWED_CRAWLERS_FILE":
		if value != "" {
			cfg.AllowedCrawlersFile = value
		}
	case "HTTP_BOT_DENIED_CRAWLERS_FILE":
		if value != "" {
			cfg.DeniedCrawlersFile = value
		}
	case "HTTP_BOT_LOG_LEVEL":
		if value != "" {
			cfg.LogLevel = strings.ToUpper(value)
		}
	case "HTTP_BOT_LOG_DECISIONS":
		cfg.LogDecisions = parseBool(value)
	}
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
