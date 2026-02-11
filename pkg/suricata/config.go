// =============================================================================
// NFTBan - Suricata Integration Configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="config"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Configuration management for Suricata filter integration"
// meta:input="Suricata filter configuration files"
// meta:output="Filter configurations"
// meta:depends="os,time"
// meta:inventory.files="/etc/nftban/suricata/filters/*.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/suricata/suricata.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/timeutil"
)

// FilterConfig represents a single Suricata filter configuration
type FilterConfig struct {
	Name        string
	Enabled     bool
	Keywords    []string
	Threshold   int
	BanTime     time.Duration
	Action      string // "log", "observe", "ban"
	BanType     string // "temporary", "permanent", "escalate"
	MaxBans     int    // For escalate: after X temp bans, go permanent
	Period      time.Duration // For escalate: count bans in this period
	Description string
}

// Config holds the complete Suricata filter configuration
type Config struct {
	GlobalEnabled      bool
	DefaultThreshold   int
	DefaultBanTime     time.Duration
	DefaultAction      string
	ScoreDecay         time.Duration
	Filters            map[string]*FilterConfig
}

// LoadConfig loads Suricata filter configuration from files
// Loads filters.conf first, then filters.conf.local overrides
func LoadConfig(configDir string) (*Config, error) {
	cfg := &Config{
		GlobalEnabled:    true,
		DefaultThreshold: 100,
		DefaultBanTime:   30 * time.Minute,
		DefaultAction:    "ban",
		ScoreDecay:       1 * time.Hour,
		Filters:          make(map[string]*FilterConfig),
	}

	// Load default config
	defaultPath := configDir + "/filters.conf"
	if err := cfg.parseConfigFile(defaultPath); err != nil {
		// If default doesn't exist, that's OK (use built-in defaults)
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("failed to parse %s: %w", defaultPath, err)
		}
	}

	// Load local overrides
	localPath := configDir + "/filters.conf.local"
	if err := cfg.parseConfigFile(localPath); err != nil {
		// Local file is optional
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("failed to parse %s: %w", localPath, err)
		}
	}

	// Central override (nftban.conf.local — highest priority)
	nftbanCfg := nftbanconf.MustLoad()
	centralLocal := nftbanCfg.ConfigDir + "/nftban.conf.local"
	if err := cfg.parseConfigFile(centralLocal); err != nil {
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("failed to parse %s: %w", centralLocal, err)
		}
	}

	return cfg, nil
}

// parseConfigFile parses a single config file
func (c *Config) parseConfigFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	lines := strings.Split(string(data), "\n")
	var currentSection string

	for lineNum, line := range lines {
		line = strings.TrimSpace(line)

		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Section headers
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			currentSection = strings.Trim(line, "[]")
			continue
		}

		// Key-value pairs
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		if currentSection == "global" {
			c.parseGlobalSetting(key, value)
		} else if currentSection == "filters" {
			if err := c.parseFilterLine(key, value, lineNum+1); err != nil {
				// Log warning but continue parsing
				fmt.Fprintf(os.Stderr, "Warning: %s:%d: %v\n", path, lineNum+1, err)
			}
		}
	}

	return nil
}

// parseGlobalSetting parses a global configuration setting
func (c *Config) parseGlobalSetting(key, value string) {
	switch key {
	case "enabled":
		c.GlobalEnabled = (value == "true" || value == "yes" || value == "1")
	case "default_threshold":
		if val, err := strconv.Atoi(value); err == nil {
			c.DefaultThreshold = val
		}
	case "default_ban_time":
		if dur, err := timeutil.ParseDuration(value); err == nil {
			c.DefaultBanTime = dur
		}
	case "default_action":
		c.DefaultAction = value
	case "score_decay":
		if dur, err := timeutil.ParseDuration(value); err == nil {
			c.ScoreDecay = dur
		}
	}
}

// parseFilterLine parses a single filter line
// Format: filter_name = enabled | keywords | threshold | ban_time | action | ban_type | description
// ban_type can be: temporary, permanent, or escalate:3:24h (escalate after 3 bans in 24h)
func (c *Config) parseFilterLine(name, value string, lineNum int) error {
	// Split by pipe separator
	parts := strings.Split(value, "|")
	if len(parts) != 7 {
		return fmt.Errorf("filter '%s' invalid format (expected 7 fields, got %d)", name, len(parts))
	}

	// Trim all parts
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}

	// Parse enabled
	enabled := (parts[0] == "true" || parts[0] == "yes" || parts[0] == "1")

	// Parse keywords
	keywordsStr := strings.TrimSpace(parts[1])
	keywords := []string{}
	if keywordsStr != "" {
		for _, kw := range strings.Split(keywordsStr, ",") {
			kw = strings.TrimSpace(kw)
			if kw != "" {
				keywords = append(keywords, strings.ToLower(kw))
			}
		}
	}

	// Parse threshold
	threshold, err := strconv.Atoi(parts[2])
	if err != nil {
		return fmt.Errorf("filter '%s' invalid threshold: %v", name, err)
	}

	// Parse ban_time
	banTime, err := timeutil.ParseDuration(parts[3])
	if err != nil {
		return fmt.Errorf("filter '%s' invalid ban_time: %v", name, err)
	}

	// Parse action
	action := strings.ToLower(parts[4])
	if action != "log" && action != "observe" && action != "ban" {
		return fmt.Errorf("filter '%s' invalid action '%s' (must be log/observe/ban)", name, action)
	}

	// Parse ban_type (temporary, permanent, or escalate:3:24h)
	banTypeStr := strings.TrimSpace(parts[5])
	banType := "temporary"
	maxBans := 0
	period := time.Duration(0)

	if strings.HasPrefix(banTypeStr, "escalate:") {
		// Format: escalate:3:24h (escalate after 3 bans in 24h)
		escalateParts := strings.Split(banTypeStr, ":")
		if len(escalateParts) != 3 {
			return fmt.Errorf("filter '%s' invalid escalate format (expected escalate:COUNT:PERIOD)", name)
		}
		banType = "escalate"
		if val, err := strconv.Atoi(escalateParts[1]); err == nil {
			maxBans = val
		} else {
			return fmt.Errorf("filter '%s' invalid escalate count: %v", name, err)
		}
		if dur, err := timeutil.ParseDuration(escalateParts[2]); err == nil {
			period = dur
		} else {
			return fmt.Errorf("filter '%s' invalid escalate period: %v", name, err)
		}
	} else {
		// Simple: temporary or permanent
		banType = strings.ToLower(banTypeStr)
		if banType != "temporary" && banType != "permanent" {
			return fmt.Errorf("filter '%s' invalid ban_type '%s' (must be temporary/permanent/escalate:N:PERIOD)", name, banType)
		}
	}

	// Description
	description := parts[6]

	// Create or update filter
	filter := &FilterConfig{
		Name:        name,
		Enabled:     enabled,
		Keywords:    keywords,
		Threshold:   threshold,
		BanTime:     banTime,
		Action:      action,
		BanType:     banType,
		MaxBans:     maxBans,
		Period:      period,
		Description: description,
	}

	c.Filters[name] = filter
	return nil
}

// GetEnabledFilters returns only enabled filters
func (c *Config) GetEnabledFilters() map[string]*FilterConfig {
	enabled := make(map[string]*FilterConfig)
	for name, filter := range c.Filters {
		if filter.Enabled {
			enabled[name] = filter
		}
	}
	return enabled
}

// GetFilter returns a specific filter by name
func (c *Config) GetFilter(name string) (*FilterConfig, bool) {
	filter, ok := c.Filters[name]
	return filter, ok
}
