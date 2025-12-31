package persistent

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// Config holds persistent offender configuration
type Config struct {
	GlobalThreshold int
	GlobalPeriod    time.Duration
	GlobalAction    string
	Enabled         bool

	BanLog       string
	OffendersLog string
	OffendersConf string

	// Per-filter thresholds (v1.0: renamed from jail)
	Filters map[string]*FilterConfig
}

// FilterConfig holds configuration for a specific filter (v1.0: renamed from JailConfig)
type FilterConfig struct {
	Name      string
	Threshold int
	Period    time.Duration
	Action    string
	Comment   string
}

// getDefaultPersistentPaths returns paths from central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getDefaultPersistentPaths() (configDir, logDir string) {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir, cfg.LogDir
}

// LoadConfig loads persistent offender configuration from files
// Removed: fail2ban.conf references (v1.0 migration to Suricata)
// .local settings override defaults
func LoadConfig(configDir string) (*Config, error) {
	defaultConfigDir, defaultLogDir := getDefaultPersistentPaths()

	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Enabled:         true,
		BanLog:          defaultLogDir + "/bans.log",
		OffendersLog:    defaultLogDir + "/persistent-offenders.log",
		OffendersConf:   defaultConfigDir + "/blacklist.d/30-persistent-offenders.conf",
		Filters:         make(map[string]*FilterConfig),
	}

	// Read default config
	defaultPath := configDir + "/persistent.conf" // Removed: fail2ban.conf (v1.0)
	if err := cfg.parseConfigFile(defaultPath); err != nil {
		// If default doesn't exist, use built-in defaults (not an error)
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("failed to parse %s: %w", defaultPath, err)
		}
	}

	// Read local overrides
	localPath := configDir + "/persistent.conf.local" // Removed: fail2ban.conf.local (v1.0)
	if err := cfg.parseConfigFile(localPath); err != nil {
		// Local file is optional
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("failed to parse %s: %w", localPath, err)
		}
	}

	return cfg, nil
}

// parseConfigFile parses an INI-style config file
func (c *Config) parseConfigFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	lines := strings.Split(string(data), "\n")
	var currentSection string

	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Section headers
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			currentSection = strings.Trim(line, "[]")
			if currentSection != "global" {
				// Create filter config if it doesn't exist
				if _, exists := c.Filters[currentSection]; !exists {
					c.Filters[currentSection] = &FilterConfig{
						Name:      currentSection,
						Threshold: c.GlobalThreshold,
						Period:    c.GlobalPeriod,
						Action:    c.GlobalAction,
					}
				}
			}
			continue
		}

		// Key-value pairs
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		// Remove inline comments
		if idx := strings.Index(value, "#"); idx >= 0 {
			value = strings.TrimSpace(value[:idx])
		}

		if currentSection == "global" {
			c.parseGlobalSetting(key, value)
		} else if filter, exists := c.Filters[currentSection]; exists {
			c.parseFilterSetting(filter, key, value)
		}
	}

	return nil
}

// parseGlobalSetting parses a global configuration setting
func (c *Config) parseGlobalSetting(key, value string) {
	switch key {
	case "default_threshold":
		if val, err := strconv.Atoi(value); err == nil {
			c.GlobalThreshold = val
		}
	case "default_period":
		if dur, err := parseDuration(value); err == nil {
			c.GlobalPeriod = dur
		}
	case "default_action":
		c.GlobalAction = value
	case "enabled":
		c.Enabled = (value == "true" || value == "yes" || value == "1")
	case "ban_log":
		c.BanLog = value
	case "offenders_log":
		c.OffendersLog = value
	case "offenders_conf":
		c.OffendersConf = value
	}
}

// parseFilterSetting parses a filter-specific configuration setting (v1.0: renamed from parseJailSetting)
func (c *Config) parseFilterSetting(filter *FilterConfig, key, value string) {
	switch key {
	case "threshold":
		if val, err := strconv.Atoi(value); err == nil {
			filter.Threshold = val
		}
	case "period":
		if dur, err := parseDuration(value); err == nil {
			filter.Period = dur
		}
	case "action":
		filter.Action = value
	case "comment":
		filter.Comment = strings.Trim(value, "\"")
	}
}

// parseDuration parses duration strings like "24h", "48h", "7d"
func parseDuration(s string) (time.Duration, error) {
	s = strings.ToLower(s)

	// Handle days
	if strings.HasSuffix(s, "d") {
		days, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
		if err != nil {
			return 0, err
		}
		return time.Duration(days) * 24 * time.Hour, nil
	}

	// Use standard time.ParseDuration for h, m, s
	return time.ParseDuration(s)
}

// GetFilterConfig returns configuration for a specific filter (v1.0: renamed from GetJailConfig)
// If filter not found, returns global defaults
func (c *Config) GetFilterConfig(filterName string) *FilterConfig {
	if filter, exists := c.Filters[filterName]; exists {
		return filter
	}

	// Return global defaults
	return &FilterConfig{
		Name:      filterName,
		Threshold: c.GlobalThreshold,
		Period:    c.GlobalPeriod,
		Action:    c.GlobalAction,
	}
}
